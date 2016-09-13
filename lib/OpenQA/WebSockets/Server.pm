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
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::WebSockets::Server;
use Mojolicious::Lite;
use Mojo::Util 'hmac_sha1_sum';

use OpenQA::IPC;
use OpenQA::Utils qw/log_debug log_warning/;
use OpenQA::Schema;
use OpenQA::ServerStartup;

use db_profiler;

require Exporter;
our (@ISA, @EXPORT, @EXPORT_OK);

@ISA       = qw/Exporter/;
@EXPORT    = qw/ws_send ws_send_all/;
@EXPORT_OK = qw/ws_create ws_is_worker_connected ws_add_worker ws_remove_worker/;

# worker->websockets mapping
my $worker_sockets = {};

# internal helpers prototypes
sub _message;
sub _get_worker;

# websockets helper functions
sub ws_add_worker {
    my ($workerid, $ws_connection) = @_;
    $worker_sockets->{$workerid} = $ws_connection;
}

sub ws_remove_worker {
    my ($workerid) = @_;
    delete $worker_sockets->{$workerid};
}

sub ws_send {
    my ($workerid, $msg, $jobid, $retry) = @_;
    return unless ($workerid && $msg);
    $jobid ||= '';
    my $res;
    my $tx = $worker_sockets->{$workerid};
    if ($tx) {
        $res = $tx->send({json => {type => $msg, jobid => $jobid}});
    }
    unless ($res && $res->success) {
        $retry ||= 0;
        if ($retry < 3) {
            Mojo::IOLoop->timer(2 => sub { ws_send($workerid, $msg, $jobid, ++$retry); });
        }
        else {
            log_debug("Unable to send command \"$msg\" to worker $workerid");
        }
    }
}

sub ws_send_all {
    my ($msg) = @_;
    foreach my $workerid (keys(%$worker_sockets)) {
        ws_send($workerid, $msg);
    }
}

sub check_authorized {
    my ($self)    = @_;
    my $headers   = $self->req->headers;
    my $key       = $headers->header('X-API-Key');
    my $hash      = $headers->header('X-API-Hash');
    my $timestamp = $headers->header('X-API-Microtime');
    my $user;
    $self->app->log->debug($key ? "API key from client: *$key*" : "No API key from client.");

    my $schema = OpenQA::Schema::connect_db;
    my $api_key = $schema->resultset("ApiKeys")->find({key => $key});
    if ($api_key) {
        if (time - $timestamp <= 300) {
            my $exp = $api_key->t_expiration;
            # It has no expiration date or it's in the future
            if (!$exp || $exp->epoch > time) {
                if (my $secret = $api_key->secret) {
                    my $sum = hmac_sha1_sum($self->req->url->to_string . $timestamp, $secret);
                    $user = $api_key->user;
                    $self->app->log->debug(sprintf "API auth by user: %s, operator: %d", $user->username, $user->is_operator);
                }
            }
        }
    }
    return 1 if ($user && $user->is_operator);

    $self->render(json => {error => "Not authorized"}, status => 403);
    return;
}

sub ws_create {
    my ($self)   = @_;
    my $workerid = $self->param('workerid');
    my $worker   = _validate_workerid($workerid);
    unless ($worker) {
        return $self->render(text => 'Unauthorized', status =>);
    }
    # upgrade connection to websocket by subscribing to events
    $self->on(json   => \&_message);
    $self->on(finish => \&_finish);
    ws_add_worker($workerid, $self->tx->max_websocket_size(10485760));
    return $self->render(text => 'ack', status => 101);
}

sub ws_is_worker_connected {
    my ($workerid) = @_;
    return (defined $worker_sockets->{$workerid} ? 1 : 0);
}

# internal helpers
sub _validate_workerid {
    my ($workerid) = @_;
    return app->schema->resultset("Workers")->find($workerid);
}

sub _get_workerid {
    my ($tx) = @_;
    my $ret;
    while (my ($id, $stored_tx) = each %$worker_sockets) {
        if ($stored_tx->connection eq $tx->connection) {
            $ret = $id;
        }
    }
    # reset hash iterator
    keys(%$worker_sockets);
    return $ret;
}

sub _finish {
    my ($ws, $code, $reason) = @_;
    return unless ($ws);

    my $workerid = _get_workerid($ws->tx);
    unless ($workerid) {
        $ws->app->log->error('Worker ID not found for given connection during connection close');
        return;
    }
    $ws->app->log->debug("Worker $workerid websocket connection closed - $code\n");
    ws_remove_worker($workerid);
}

sub _message {
    my ($ws, $json) = @_;
    my $workerid = _get_workerid($ws->tx);
    unless ($workerid) {
        $ws->app->log->warn("A message received from unknown worker connection");
        return;
    }
    unless (ref($json) eq 'HASH') {
        use Data::Dumper;
        $ws->app->log->error(sprintf('Received unexpected WS message "%s from worker %u', Dumper($json), $workerid));
        return;
    }

    my $worker = _validate_workerid($workerid);
    $worker->seen();
    if ($json->{type} eq 'ok') {
        $ws->tx->send({json => {type => 'ok'}});
    }
    elsif ($json->{type} eq 'status') {
        # handle job status update through web socket
        my $jobid  = $json->{jobid};
        my $status = $json->{data};
        my $job    = $ws->app->schema->resultset("Jobs")->find($jobid);
        return $ws->tx->send(json => {result => 'nack'}) unless $job;
        my $ret = $job->update_status($status);
        $ws->tx->send({json => $ret});
    }
    elsif ($json->{type} eq 'property_change') {
        my $prop = $json->{data};
        if (defined $prop->{interactive_mode}) {
            $worker->set_property('INTERACTIVE_REQUESTED', $prop->{interactive_mode} ? 1 : 0);
        }
        elsif (defined $prop->{waitforneedle}) {
            $worker->set_property('STOP_WAITFORNEEDLE_REQUESTED', $prop->{waitforneedle} ? 1 : 0);
        }
        else {
            $ws->app->log->error("Unknown property received from worker $workerid");
        }
    }
    else {
        $ws->app->log->error(sprintf('Received unknown message type "%s" from worker %u', $json->{type}, $workerid));
    }
}

sub _get_stale_worker_jobs {
    my ($threshold) = @_;

    my $schema = OpenQA::Schema::connect_db;

    my $dtf = $schema->storage->datetime_parser;
    my $dt = DateTime->from_epoch(epoch => time() - $threshold, time_zone => 'UTC');

    my %cond = (
        state              => [OpenQA::Schema::Result::Jobs::EXECUTION_STATES],
        'worker.t_updated' => {'<' => $dtf->format_datetime($dt)},
    );
    my %attrs = (join => 'worker',);

    return $schema->resultset("Jobs")->search(\%cond, \%attrs);
}

sub _is_job_considered_dead {
    my ($job) = @_;

    # much bigger timeout for uploading jobs; while uploading files,
    # worker process is blocked and cannot send status updates
    if ($job->state eq OpenQA::Schema::Result::Jobs::UPLOADING) {
        my $delta = DateTime->now()->epoch() - $job->worker->t_updated->epoch();
        log_debug("uploading worker not updated for $delta seconds " . $job->id);
        return ($delta > 1000);
    }

    log_debug("job considered dead: " . $job->id);
    # default timeout for the rest
    return 1;
}

# Check if worker with job has been updated recently; if not, assume it
# got stuck somehow and duplicate or incomplete the job
sub _workers_checker {

    my $stale_jobs = _get_stale_worker_jobs(40);
    my $ipc        = OpenQA::IPC->ipc;
    for my $job ($stale_jobs->all) {
        next unless _is_job_considered_dead($job);

        $job->done(result => OpenQA::Schema::Result::Jobs::INCOMPLETE);
        my $res = $ipc->scheduler('job_duplicate', {jobid => $job->id});
        if ($res) {
            log_warning(sprintf('dead job %d aborted and duplicated', $job->id));
        }
        else {
            log_warning(sprintf('dead job %d aborted as incomplete', $job->id));
        }
    }
}

# Mojolicious startup
sub setup {
    app->helper(schema => sub { return OpenQA::Schema::connect_db; });
    # not really meaningful for websockets, but required for mode defaults
    app->helper(mode     => sub { return 'production' });
    app->helper(log_name => sub { return 'websockets' });
    OpenQA::ServerStartup::read_config(app);
    OpenQA::ServerStartup::setup_logging(app);

    # use port one higher than WebAPI
    my $port = 9527;
    if ($ENV{MOJO_LISTEN} && $ENV{MOJO_LISTEN} =~ /.*:(\d{1,5})\/?$/) {
        $port = $1;
    }

    under \&check_authorized;
    websocket '/ws/:workerid' => [workerid => qr/\d+/] => \&ws_create;

    # no cookies for worker, no secrets to protect
    app->secrets(['nosecretshere']);

    # start worker checker - check workers each 2 minutes
    Mojo::IOLoop->recurring(120 => \&_workers_checker);

    return Mojo::Server::Daemon->new(app => app, listen => ["http://localhost:$port"]);
}


1;
