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
use FindBin;
use lib "$FindBin::Bin/lib";
use OpenQA::Scheduler;
use OpenQA::WebSockets;
use OpenQA::Constants 'WEBSOCKET_API_VERSION';
use OpenQA::Test::Database;
use Test::MockModule;
use DBIx::Class::Timestamps 'now';
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

my $job = job_get(99963);
is_deeply(
    $job->cluster_jobs,
    {
        99961 => {
            chained_children  => [],
            chained_parents   => [],
            parallel_children => [99963],
            parallel_parents  => [],
        },
        99963 => {
            chained_children  => [],
            chained_parents   => [],
            parallel_children => [],
            parallel_parents  => [99961],
        },
    },
    "99963 is part of a duett"
);
my $new_job = $job->auto_duplicate;
ok($new_job, "got new job id " . $new_job->id);

is($new_job->state, 'scheduled', "new job is scheduled");
is_deeply(
    $new_job->cluster_jobs,
    {
        99982 => {
            chained_children  => [],
            chained_parents   => [],
            parallel_children => [99983],
            parallel_parents  => [],
        },
        99983 => {
            chained_children  => [],
            chained_parents   => [],
            parallel_children => [],
            parallel_parents  => [99982],
        },
    },
    "new job is part of a new duett"
);

$job = job_get(99963);
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
# 99963 and the new cluster of 2
is($ret, 3, "two jobs cancelled by hash");

$job = $new_job;

lj;

$job = $new_job->discard_changes;
is($job->state, 'cancelled', "new job is cancelled");
ok($job->t_finished, "There is a finish time");

$job = job_get(99963);
is($job->state, 'cancelled', "old job cancelled as well");

$job = job_get(99982);
is($job->state, 'cancelled', "new job 99982 cancelled");

$job = job_get(99983);
is($job->state, 'cancelled', "new job 99983 cancelled");

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

    $jobA->state(OpenQA::Jobs::Constants::RUNNING);
    $jobA->update;

    # set A as failed and reload B, C from database
    $jobA->done(result => OpenQA::Jobs::Constants::FAILED);
    $jobB->discard_changes;
    $jobC->discard_changes;

    is($jobB->state,  OpenQA::Jobs::Constants::CANCELLED, 'B state is cancelled');
    is($jobC->state,  OpenQA::Jobs::Constants::CANCELLED, 'C state is cancelled');
    is($jobB->result, OpenQA::Jobs::Constants::SKIPPED,   'B result is skipped');
    is($jobC->result, OpenQA::Jobs::Constants::SKIPPED,   'C result is skipped');
};

subtest 'parallel parent fails -> children are cancelled (parallel_failed)' => sub {
    # monkey patch ws_send of OpenQA::WebSockets::Server to store received command
    my (@commands, $server_called);
    my $mock_server = Test::MockModule->new('OpenQA::WebSockets::Server');
    $mock_server->mock(
        ws_send => sub {
            my ($workerid, $command, $jobid) = @_;
            $server_called++;
            push @OpenQA::WebSockets::Server::commands, $command;
        });

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
    $workercaps->{websocket_api_version}        = WEBSOCKET_API_VERSION;
    $workercaps->{isotovideo_interface_version} = WEBSOCKET_API_VERSION;
    use OpenQA::WebAPI::Controller::API::V1::Worker;
    my $c  = OpenQA::WebAPI::Controller::API::V1::Worker->new;
    my $w1 = $schema->resultset('Workers')->find($c->_register($schema, "host", "1", $workercaps));
    my $w2 = $schema->resultset('Workers')->find($c->_register($schema, "host", "2", $workercaps));
    my $w3 = $schema->resultset('Workers')->find($c->_register($schema, "host", "3", $workercaps));

    $jobA->state(OpenQA::Jobs::Constants::RUNNING);
    $w1->job($jobA);
    $jobB->state(OpenQA::Jobs::Constants::RUNNING);
    $w2->job($jobB);
    $jobC->state(OpenQA::Jobs::Constants::RUNNING);
    $w3->job($jobC);
    $_->update for ($jobA, $jobB, $jobC, $w1, $w2, $w3);

    # set A as failed and reload B, C from database
    @OpenQA::WebSockets::Server::commands = ();
    my $now = now();
    $jobA->done(result => OpenQA::Jobs::Constants::FAILED);
    $jobB->discard_changes;
    $jobC->discard_changes;

    is($jobB->result, OpenQA::Jobs::Constants::PARALLEL_FAILED, 'B result is parallel failed');
    is($jobB->state, OpenQA::Jobs::Constants::RUNNING, 'B is still running');
    is($jobB->t_finished, undef, 'B does not has t_finished set since it is still running');
    is($jobC->result, OpenQA::Jobs::Constants::PARALLEL_FAILED, 'C result is parallel failed');
    is_deeply(\@OpenQA::WebSockets::Server::commands, [qw(cancel cancel)], 'both cancel commands issued');

    # assume B has actually been cancelled
    $jobB->update({state => OpenQA::Jobs::Constants::DONE});
    ok($jobB->t_finished, 'B has t_finished set after being actually cancelled')
      and ok($jobB->t_finished ge $now, 'B has t_finished set to a sane value');

    ok $server_called, 'Mocked ws_send function has been called';
};

subtest 'chained parent fails -> parallel parents of children are cancelled (skipped)' => sub {
    my %settingsA = %settings;
    my %settingsB = %settings;
    my %settingsC = %settings;
    my %settingsD = %settings;

    # https://progress.opensuse.org/issues/36565 - A is install, B is support server,
    # C and D are children to both and parallel to each other
    $settingsA{TEST} = 'A';
    $settingsB{TEST} = 'B';
    $settingsC{TEST} = 'C';
    $settingsD{TEST} = 'D';

    my $jobA = _job_create(\%settingsA);
    my $jobB = _job_create(\%settingsB);
    $settingsC{_START_AFTER_JOBS} = [$jobA->id];
    $settingsD{_START_AFTER_JOBS} = [$jobA->id];
    $settingsC{_PARALLEL_JOBS}    = [$jobB->id];
    my $jobC = _job_create(\%settingsC);
    $settingsC{_PARALLEL_JOBS} = [$jobB->id, $jobC->id];
    my $jobD = _job_create(\%settingsD);

    $jobA->state(OpenQA::Jobs::Constants::RUNNING);
    $jobA->update;

    # set A as failed and reload B, C and D from database
    $jobA->done(result => OpenQA::Jobs::Constants::FAILED);
    $jobB->discard_changes;
    $jobC->discard_changes;
    $jobD->discard_changes;

    is($jobB->state,  OpenQA::Jobs::Constants::CANCELLED, 'B state is cancelled');
    is($jobC->state,  OpenQA::Jobs::Constants::CANCELLED, 'C state is cancelled');
    is($jobD->state,  OpenQA::Jobs::Constants::CANCELLED, 'D state is cancelled');
    is($jobB->result, OpenQA::Jobs::Constants::SKIPPED,   'B result is skipped');
    is($jobC->result, OpenQA::Jobs::Constants::SKIPPED,   'C result is skipped');
    is($jobD->result, OpenQA::Jobs::Constants::SKIPPED,   'D result is skipped');
};

subtest 'parallel child with one parent fails -> parent is cancelled' => sub {
    my %settingsA = %settings;
    my %settingsB = %settings;
    $settingsA{TEST} = 'A';
    $settingsB{TEST} = 'B';
    my $jobA = _job_create(\%settingsA);
    $settingsB{_PARALLEL_JOBS} = [$jobA->id];
    my $jobB = _job_create(\%settingsB);

    # set B as failed and reload A from database
    $jobB->done(result => OpenQA::Jobs::Constants::FAILED);
    $jobA->discard_changes;

    is($jobA->state, OpenQA::Jobs::Constants::CANCELLED, 'A state is cancelled');
};

subtest 'failure behaviour for multiple parallel children' => sub {
    my %settingsA = %settings;
    my %settingsB = %settings;
    my %settingsC = %settings;
    $settingsA{TEST} = 'A';
    $settingsB{TEST} = 'B';
    $settingsC{TEST} = 'C';
    my $jobA = _job_create(\%settingsA);
    $settingsB{_PARALLEL_JOBS} = [$jobA->id];
    $settingsC{_PARALLEL_JOBS} = [$jobA->id];
    my $jobB = _job_create(\%settingsB);
    my $jobC = _job_create(\%settingsC);

    # set B as failed and reload A and C from database
    $jobB->done(result => OpenQA::Jobs::Constants::FAILED);
    $jobA->discard_changes;
    $jobC->discard_changes;

    # A and C should be cancelled
    is($jobA->state, OpenQA::Jobs::Constants::CANCELLED, 'A state is cancelled');
    is($jobC->state, OpenQA::Jobs::Constants::CANCELLED, 'C state is cancelled');

    # now test in 'do not cancel parent and other children' mode
    $settingsA{PARALLEL_CANCEL_WHOLE_CLUSTER} = '0';
    $jobA                                     = _job_create(\%settingsA);
    $settingsB{_PARALLEL_JOBS}                = [$jobA->id];
    $settingsC{_PARALLEL_JOBS}                = [$jobA->id];
    $jobB                                     = _job_create(\%settingsB);
    $jobC                                     = _job_create(\%settingsC);

    # set B as failed and reload A and C from database
    $jobB->done(result => OpenQA::Jobs::Constants::FAILED);
    $jobA->discard_changes;
    $jobC->discard_changes;

    # this time A and C should still be scheduled (*not* cancelled)
    is($jobA->state, OpenQA::Jobs::Constants::SCHEDULED, 'new A state is scheduled');
    is($jobC->state, OpenQA::Jobs::Constants::SCHEDULED, 'new C state is scheduled');

    # now set C as failed and reload A
    $jobC->done(result => OpenQA::Jobs::Constants::FAILED);
    $jobA->discard_changes;

    # now A *should* be cancelled
    is($jobA->state, OpenQA::Jobs::Constants::CANCELLED, 'new A state is cancelled');
};

done_testing();
