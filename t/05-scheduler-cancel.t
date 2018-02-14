#!/usr/bin/env perl -w

# Copyright (C) 2014-2016 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

BEGIN {
    unshift @INC, 'lib';
    $ENV{OPENQA_TEST_IPC} = 1;
}

use strict;
# https://github.com/rurban/Cpanel-JSON-XS/issues/65
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/lib";
use Data::Dump qw(pp dd);
use OpenQA::Scheduler;
use OpenQA::WebSockets;
use OpenQA::WebSockets::Server 'INTERFACE_VERSION';
use OpenQA::Test::Database;
use Net::DBus;
use Test::More;
use Test::Warnings;

my $schema = OpenQA::Test::Database->new->create();
# create Test DBus bus and service for fake WebSockets call
my $ws = OpenQA::WebSockets->new;

sub job_get {
    my ($id) = @_;

    my $job = $schema->resultset("Jobs")->find({id => $id});
    return $job;
}

my $new_job = job_get(99963)->auto_duplicate;
ok($new_job, "got new job id " . $new_job->id);

is($new_job->state, 'scheduled', "new job is scheduled");

my $job = job_get(99963);
is($job->state,      'running', "old job is running");
is($job->t_finished, undef,     "There is a no finish time yet");

sub lj {
    # check the call succeeds every time, only output if verbose
    my @jobs = $schema->resultset('Jobs')->all;
    return unless $ENV{HARNESS_IS_VERBOSE};
    for my $j (@jobs) {
        printf "%d %-10s %s\n", $j->id, $j->state, $j->name;
    }
}

lj;

my $ret = $schema->resultset('Jobs')
  ->cancel_by_settings({DISTRI => 'opensuse', VERSION => '13.1', FLAVOR => 'DVD', ARCH => 'x86_64'});
is($ret, 2, "two jobs cancelled by hash");

$job = $new_job;

lj;

$job = $new_job->discard_changes;
is($job->state, 'cancelled', "new job is cancelled");
ok($job->t_finished, "There is a finish time");

$job = job_get(99963);
is($job->state, 'cancelled', "old job cancelled as well");

$job = job_get(99928);
is($job->state, 'scheduled', "unrelated job 99928 still scheduled");
$job = job_get(99927);
is($job->state, 'scheduled', "unrelated job 99927 still scheduled");

$job = job_get(99928);
$ret = $job->cancel;
is($ret, 1, "one job cancelled by id");

$job = job_get(99928);
is($job->state, 'cancelled', "job 99928 cancelled");
$job = job_get(99927);
is($job->state, 'scheduled', "unrelated job 99927 still scheduled");


$new_job = job_get(99981)->auto_duplicate;
ok($new_job, "duplicate new job for iso test");

$job = $new_job;
is($job->state, 'scheduled', "new job is scheduled");

lj;

$ret = $schema->resultset('Jobs')->cancel_by_settings({ISO => 'openSUSE-13.1-GNOME-Live-i686-Build0091-Media.iso'});
is($ret, 1, "one job cancelled by iso");

$job = job_get(99927);
is($job->state, 'scheduled', "unrelated job 99927 still scheduled");

my %settings = (
    DISTRI  => 'Unicorn',
    FLAVOR  => 'pink',
    VERSION => '42',
    BUILD   => '666',
    ISO     => 'whatever.iso',
    MACHINE => "RainbowPC",
    ARCH    => 'x86_64',
);

sub _job_create {
    my $job = $schema->resultset('Jobs')->create_from_settings(@_);
    # reload all values from database so we can check against default values
    $job->discard_changes;
    return $job;
}

subtest 'chained parent fails -> chilren are canceled (skipped)' => sub {
    my %settingsA = %settings;
    my %settingsB = %settings;
    my %settingsC = %settings;

    $settingsA{TEST} = 'A';
    $settingsB{TEST} = 'B';
    $settingsC{TEST} = 'C';

    my $jobA = _job_create(\%settingsA);
    $settingsB{_START_AFTER_JOBS} = [$jobA->id];
    my $jobB = _job_create(\%settingsB);
    $settingsC{_START_AFTER_JOBS} = [$jobB->id];
    my $jobC = _job_create(\%settingsC);

    $jobA->state(OpenQA::Schema::Result::Jobs::RUNNING);
    $jobA->update;

    # set A as failed and reload B, C from database
    $jobA->done(result => OpenQA::Schema::Result::Jobs::FAILED);
    $jobB->discard_changes;
    $jobC->discard_changes;

    is($jobB->state,  OpenQA::Schema::Result::Jobs::CANCELLED, 'B state is cancelled');
    is($jobC->state,  OpenQA::Schema::Result::Jobs::CANCELLED, 'C state is cancelled');
    is($jobB->result, OpenQA::Schema::Result::Jobs::SKIPPED,   'B result is skipped');
    is($jobC->result, OpenQA::Schema::Result::Jobs::SKIPPED,   'C result is skipped');
};

subtest 'parallel parent fails -> children are cancelled (parallel_failed)' => sub {
    # monkey patch ws_send of OpenQA::WebSockets::Server to store received command
    package OpenQA::WebSockets::Server;
    no warnings "redefine";
    my @commands = ();
    sub ws_send {
        my ($workerid, $command, $jobid) = @_;
        push @OpenQA::WebSockets::Server::commands, $command;
    }

    package main;
    my %settingsA = %settings;
    my %settingsB = %settings;
    my %settingsC = %settings;

    $settingsA{TEST} = 'A';
    $settingsB{TEST} = 'B';
    $settingsC{TEST} = 'C';

    my $jobA = _job_create(\%settingsA);
    $settingsB{_PARALLEL_JOBS} = [$jobA->id];
    my $jobB = _job_create(\%settingsB);
    $settingsC{_PARALLEL_JOBS} = [$jobA->id];
    my $jobC = _job_create(\%settingsC);

    # we need 3 workers for command issue test
    my $workercaps = {};
    $workercaps->{cpu_modelname}                = 'Rainbow CPU';
    $workercaps->{cpu_arch}                     = 'x86_64';
    $workercaps->{cpu_opmode}                   = '32-bit, 64-bit';
    $workercaps->{mem_max}                      = '4096';
    $workercaps->{websocket_api_version}        = INTERFACE_VERSION;
    $workercaps->{isotovideo_interface_version} = INTERFACE_VERSION;
    use OpenQA::WebAPI::Controller::API::V1::Worker;
    my $c  = OpenQA::WebAPI::Controller::API::V1::Worker->new;
    my $w1 = $schema->resultset('Workers')->find($c->_register($schema, "host", "1", $workercaps));
    my $w2 = $schema->resultset('Workers')->find($c->_register($schema, "host", "2", $workercaps));
    my $w3 = $schema->resultset('Workers')->find($c->_register($schema, "host", "3", $workercaps));

    $jobA->state(OpenQA::Schema::Result::Jobs::RUNNING);
    $w1->job($jobA);
    $jobB->state(OpenQA::Schema::Result::Jobs::RUNNING);
    $w2->job($jobB);
    $jobC->state(OpenQA::Schema::Result::Jobs::RUNNING);
    $w3->job($jobC);
    $_->update for ($jobA, $jobB, $jobC, $w1, $w2, $w3);

    # set A as failed and reload B, C from database
    @OpenQA::WebSockets::Server::commands = ();
    $jobA->done(result => OpenQA::Schema::Result::Jobs::FAILED);
    $jobB->discard_changes;
    $jobC->discard_changes;

    is($jobB->result, OpenQA::Schema::Result::Jobs::PARALLEL_FAILED, 'B result is parallel failed');
    is($jobC->result, OpenQA::Schema::Result::Jobs::PARALLEL_FAILED, 'C result is parallel failed');
    is_deeply(\@OpenQA::WebSockets::Server::commands, [qw(cancel cancel)], 'both cancel commands issued');
};

done_testing();
