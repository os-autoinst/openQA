# Copyright 2014-2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebSockets;
use Mojo::Base 'Mojolicious';

use Mojo::Server::Daemon;
use OpenQA::Setup;
use OpenQA::Log qw(log_debug log_warning log_info setup_log);
use OpenQA::WebSockets::Model::Status;

our $RUNNING;

sub startup {
    my $self = shift;

    OpenQA::WebSockets::Client::mark_current_process_as_websocket_server;

    $self->_setup if $RUNNING;

    $self->defaults(appname => 'openQA Websocket Server');

    # no cookies for worker, no secrets to protect
    $self->secrets(['nosecretshere']);
    $self->config->{no_localhost_auth} ||= 1;

    # Some plugins are shared between openQA micro services
    push @{$self->plugins->namespaces}, 'OpenQA::Shared::Plugin', 'OpenQA::WebSockets::Plugin';
    $self->plugin('Helpers');
    $self->plugin('SharedHelpers');

    # Some controllers are shared between openQA micro services
    my $r = $self->routes->namespaces(['OpenQA::Shared::Controller', 'OpenQA::WebSockets::Controller']);

    my $ca = $r->under('/')->to('Auth#check');
    $ca->get('/' => {json => {name => $self->defaults('appname')}});
    my $api = $ca->any('/api');
    $api->post('/send_job')->to('API#send_job');
    $api->post('/send_jobs')->to('API#send_jobs');
    $api->post('/send_msg')->to('API#send_msg');
    $ca->websocket('/ws/<workerid:num>')->to('Worker#ws');

    OpenQA::Setup::setup_plain_exception_handler($self);
}

sub run {
    local $RUNNING = 1;
    __PACKAGE__->new->start;
}

sub ws_send {
    my ($workerid, $msg, $jobid, $retry) = @_;

    return undef unless $workerid && $msg;
    return undef unless my $worker = OpenQA::WebSockets::Model::Status->singleton->workers->{$workerid};

    $jobid ||= '';
    $retry ||= 0;

    my $tx = $worker->{tx};
    if (!$tx || $tx->is_finished) {
        # uncoverable statement untested exceptional error
        log_debug("Unable to send command \"$msg\" to worker $workerid: worker not connected");

        # try again in 10 seconds because workers try to re-connect in 10 s intervals
        # uncoverable statement
        Mojo::IOLoop->timer(10 => sub { ws_send($workerid, $msg, $jobid, ++$retry); }) if ($retry < 3);
        return 0;    # uncoverable statement
    }
    $tx->send({json => {type => $msg, jobid => $jobid}});
    return 1;
}

sub ws_send_job {
    my ($job_info, $message) = @_;
    my $result = {state => {msg_sent => 0}};
    my $state = $result->{state};

    unless (ref($job_info) eq 'HASH' && exists $job_info->{assigned_worker_id}) {
        # uncoverable statement untested exceptional error
        $state->{error} = "No workerid assigned";
        return $result;    # uncoverable statement
    }

    my $worker_id = $job_info->{assigned_worker_id};
    my $worker = OpenQA::WebSockets::Model::Status->singleton->workers->{$worker_id};
    if (!$worker) {
        # uncoverable statement untested exceptional error
        $state->{error} = "Unable to assign job to worker $worker_id: the worker has not established a ws connection";
        return $result;    # uncoverable statement
    }

    my $tx = $worker->{tx};
    if (!$tx || $tx->is_finished) {
        $state->{error} = "Unable to assign job to worker $worker_id: the worker is not connected anymore";
        return $result;
    }

    my $job_ids = ref($job_info->{ids}) eq 'ARRAY' ? $job_info->{ids} : [$job_info->{id} // ()];
    $tx->send({json => $message});
    my $id_string = join(', ', @$job_ids) || '?';
    log_debug("Started to send message to $worker_id for job(s) $id_string");
    $state->{msg_sent} = 1;
    return $result;
}

sub _setup {
    my $self = shift;

    OpenQA::Setup::read_config($self);
    setup_log($self);
}

1;
