# Copyright 2019-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebSockets::Controller::API;
use Mojo::Base 'Mojolicious::Controller';

use OpenQA::Constants qw(WORKER_COMMAND_GRAB_JOB WORKER_COMMAND_GRAB_JOBS);
use OpenQA::WebSockets;
use OpenQA::WebSockets::Model::Status;

sub send_msg {
    my ($self) = @_;

    my $data = $self->req->json;
    my $worker_id = $data->{worker_id};
    my $msg = $data->{msg};
    my $job_id = $data->{job_id};
    my $retry = $data->{retry};

    my $result = OpenQA::WebSockets::ws_send($worker_id, $msg, $job_id, $retry);
    $self->render(json => {result => $result});
}

sub send_job {
    my ($self) = @_;

    my $job = $self->req->json;
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
