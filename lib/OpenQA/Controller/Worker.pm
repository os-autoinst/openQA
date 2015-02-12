# Copyright (C) 2014 SUSE Linux Products GmbH
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

package OpenQA::Controller::Worker;
use Mojo::Base 'Mojolicious::Controller';
use OpenQA::Utils;
use OpenQA::Scheduler qw/list_workers worker_get workers_get_dead_worker job_get_by_workerid/;
use OpenQA::WebSockets qw/ws_get_connected_workers/;

sub workers_amount {
    my $self = shift;

    my $workers_ref = list_workers();
    my $workers_amount = scalar(@$workers_ref) - 1;

    return $workers_amount;
}

sub worker_info($) {
    my $workerid = shift;

    my $worker = worker_get($workerid);
    my $job = job_get_by_workerid($workerid);
    my $settings = {
        workerid => $workerid,
        host => $worker->{host},
        instance => $worker->{instance},
        backend => $worker->{backend},
        properties => $worker->{properties}
    };
    # puts job id in status, otherwise is idle
    if($job) {
        my $testdirname = $job->{'settings'}->{'NAME'};
        $settings->{status} = "running";
        $settings->{jobid} = $job->{id};
        my $schema = OpenQA::Scheduler::schema();
        my $r = $schema->resultset("JobModules")->find({ job_id => $job->{id}, result => 'running' });
        $settings->{currentstep} = $r->name if $r;
    }
    else {
        $settings->{status} = "idle";
    }
    my $dead_workers = workers_get_dead_worker();
    foreach my $dead_worker (@$dead_workers) {
        if($dead_worker->{id} == $workerid) {
            $settings->{status} = "dead";
        }
    }
    my @connected_workers = ws_get_connected_workers();
    foreach my $connected_worker (@connected_workers) {
        if($connected_worker == $workerid) {
            $settings->{connected} = 1;
        }
    }
    return $settings;
}

sub workers_list {
    my $self = shift;

    my $workers_amount = workers_amount();

    my @wlist=();

    for my $workerid (1..$workers_amount) {
        my $worker_settings = worker_info($workerid);
        push @wlist, $worker_settings;
    }
    return @wlist;
}

1;
# vim: set sw=4 et:
