# Copyright (C) 2019-2020 SUSE LLC
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

package OpenQA::WebSockets::Controller::API;
use Mojo::Base 'Mojolicious::Controller';

use OpenQA::Constants qw(WORKER_COMMAND_GRAB_JOB WORKER_COMMAND_GRAB_JOBS);
use OpenQA::WebSockets;
use OpenQA::WebSockets::Model::Status;

sub send_msg {
    my ($self) = @_;

    my $data      = $self->req->json;
    my $worker_id = $data->{worker_id};
    my $msg       = $data->{msg};
    my $job_id    = $data->{job_id};
    my $retry     = $data->{retry};

    my $result = OpenQA::WebSockets::ws_send($worker_id, $msg, $job_id, $retry);
    $self->render(json => {result => $result});
}

sub send_job {
    my ($self) = @_;

    my $job    = $self->req->json;
    my $result = OpenQA::WebSockets::ws_send_job($job, {type => WORKER_COMMAND_GRAB_JOB, job => $job});
    $self->render(json => {result => $result});
}

sub send_jobs {
    my ($self) = @_;

    my $job_info = $self->req->json;
    my $result = OpenQA::WebSockets::ws_send_job($job_info, {type => WORKER_COMMAND_GRAB_JOBS, job_info => $job_info});
    $self->render(json => {result => $result});
}

1;
