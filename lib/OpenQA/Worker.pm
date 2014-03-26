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

package OpenQA::Worker;
use Mojo::Base 'Mojolicious::Controller';
use openqa;
use Scheduler qw/list_workers worker_get job_get_by_workerid/;

sub list {
    my $self = shift;

    my $workers_ref = list_workers();
    my $workers_cnt = scalar(@$workers_ref) - 1;

    my @wlist=();

    for my $workerid (1..$workers_cnt) {
	my $worker = worker_get($workerid);
	my $job = job_get_by_workerid($workerid);
	my $settings = {
	    workerid => $workerid,
	    host => $worker->{host},
	    instance => $worker->{instance},
	    backend => $worker->{backend},
	};
        # puts job id in status, otherwise is idle
	if($job) {
	    my $testdirname = $job->{'settings'}->{'NAME'};
	    my $results = test_result($testdirname);
	    my $modinfo = get_running_modinfo($results);
	    $settings->{status} = $job->{id};
	    $settings->{currentstep} = $modinfo->{running};
	} else {
	    $settings->{status} = "idle";
	}
	push @wlist, $settings;
    }
    $self->stash(wlist => \@wlist);
    $self->stash(workers_cnt => $workers_cnt);
}

1;
