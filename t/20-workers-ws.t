# Copyright (C) 2016 SUSE LLC
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
}

use strict;
use warnings;
use DateTime;
use Test::More;
use Test::Warnings;
use OpenQA::IPC;
use OpenQA::Scheduler;
use OpenQA::WebSockets;
use OpenQA::Test::Database;

my $schema = OpenQA::Test::Database->new->create();
my $ipc = OpenQA::IPC->ipc('', 1);
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

subtest 'worker with job and not updated in last 50s is considered dead' => sub {
    _check_job_running($_) for (99961, 99963);
    # move the updated timestamp of the workers to avoid sleeping
    my $dtf = $schema->storage->datetime_parser;
    my $dt = DateTime->from_epoch(epoch => time() - 50, time_zone => 'UTC');

    $schema->resultset('Workers')->update_all({t_updated => $dtf->format_datetime($dt)});
    OpenQA::WebSockets::Server::_workers_checker();
    _check_job_incomplete($_) for (99961, 99963);
};

done_testing();
