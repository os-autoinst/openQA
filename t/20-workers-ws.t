#! /usr/bin/perl

# Copyright (C) 2016-2017 SUSE LLC
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
# with this program; if not, see <http://www.gnu.org/licenses/>.

BEGIN {
    unshift @INC, 'lib';
    $ENV{OPENQA_TEST_IPC} = 1;

}

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
# https://github.com/rurban/Cpanel-JSON-XS/issues/65
use JSON::PP;
use DateTime;
use Test::More;
use Test::Warnings;
use Test::Output qw(stderr_like);
use OpenQA::Scheduler;
use OpenQA::WebSockets;
use OpenQA::Test::Database;
use OpenQA::Test::Utils 'redirect_output';
require OpenQA::Worker::Commands;

my $schema = OpenQA::Test::Database->new->create();
OpenQA::Scheduler->new;
OpenQA::WebSockets->new;

sub _check_job_running {
    my ($jobid) = @_;
    my $job = $schema->resultset('Jobs')->find($jobid);
    is($job->state, OpenQA::Schema::Result::Jobs::RUNNING, "job $jobid is running");
    ok(!$job->clone, "job $jobid does not have a clone");
    return $job;
}

sub _check_job_incomplete {
    my ($jobid) = @_;
    my $job = $schema->resultset('Jobs')->find($jobid);
    is($job->state,  OpenQA::Schema::Result::Jobs::DONE,       "job $jobid set as done");
    is($job->result, OpenQA::Schema::Result::Jobs::INCOMPLETE, "job $jobid set as incomplete");
    ok($job->clone, "job $jobid was cloned");
    return $job;
}

subtest 'worker with job and not updated in last 120s is considered dead' => sub {
    _check_job_running($_) for (99961, 99963);
    # move the updated timestamp of the workers to avoid sleeping
    my $dtf = $schema->storage->datetime_parser;
    my $dt = DateTime->from_epoch(epoch => time() - 121, time_zone => 'UTC');

    $schema->resultset('Workers')->update_all({t_updated => $dtf->format_datetime($dt)});
    stderr_like {
        OpenQA::WebSockets::Server::_workers_checker();
    }
    qr/dead job 99961 aborted and duplicated 99983\n.*dead job 99963 aborted as incomplete/;
    _check_job_incomplete($_) for (99961, 99963);
};

my $ws = testUA->new;

no warnings qw(redefine once);
*OpenQA::Worker::Commands::stop_job = sub {
    my $reason = shift;
    $OpenQA::Worker::Common::job = $reason;
};

*OpenQA::Worker::Commands::backend_running = sub {
    return 1;
};

subtest 'worker accepted ws commands' => sub {
    $OpenQA::Worker::Common::verbose      = 1;
    $OpenQA::Worker::Common::hosts        = {host1 => {ws => $ws}};
    $OpenQA::Worker::Common::ws_to_host   = {$ws => 'host1'};
    $OpenQA::Worker::Common::current_host = 'host1';

    for my $c (qw(quit abort cancel obsolete)) {
        $OpenQA::Worker::Common::job = {id => 'job'};
        OpenQA::Worker::Commands::websocket_commands($ws, {type => $c});
        is($OpenQA::Worker::Common::job, $c, "job aborted as $c");
    }

    $OpenQA::Worker::Common::job = {id => 'job', URL => '127.0.0.1/nojob'};
    for my $c (qw(stop_waitforneedle continue_waitforneedle)) {
        OpenQA::Worker::Commands::websocket_commands($ws, {type => $c});
        is($ws->get_last_command->[0]{json}{type}, 'property_change');
        is($ws->get_last_command->[0]{json}{data}{waitforneedle}, $c eq 'stop_waitforneedle' ? 1 : 0);
    }

    for my $c (qw(enable_interactive_mode disable_interactive_mode)) {
        OpenQA::Worker::Commands::websocket_commands($ws, {type => $c});
        is($ws->get_last_command->[0]{json}{type}, 'property_change');
        is($ws->get_last_command->[0]{json}{data}{interactive_mode}, $c eq 'enable_interactive_mode' ? 1 : 0);
    }

    $OpenQA::Worker::Common::pooldir = 't';
    OpenQA::Worker::Commands::websocket_commands($ws, {type => 'livelog_start'});
    is($OpenQA::Worker::Jobs::do_livelog, 1, 'livelog is started');
    OpenQA::Worker::Commands::websocket_commands($ws, {type => 'livelog_stop'});
    is($OpenQA::Worker::Jobs::do_livelog, 0, 'livelog is stopped');

    my $buf;
    redirect_output(\$buf);
    OpenQA::Worker::Commands::websocket_commands($ws, {type => 'unknown'});
    like($buf, qr/got unknown command/, 'Unknown command');
    $buf = '';
    OpenQA::Worker::Commands::websocket_commands($ws, {type => 'incompatible'});
    like($buf, qr/The worker is running an incompatible version/, 'incompatible version');

};

done_testing();

package testUA;
sub new {
    my $type = shift;
    return bless {}, $type;
}

sub send {
    my $self = shift;
    push @{$self->{commands}}, \@_;
}

sub get_last_command {
    my $self = shift;
    return $self->{commands}[-1];
}

1;
