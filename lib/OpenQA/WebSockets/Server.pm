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
use Try::Tiny;

use OpenQA::IPC;
use OpenQA::Utils qw(log_debug log_warning log_error notify_workers);
use OpenQA::Schema;
use OpenQA::ServerStartup;

use db_profiler;

require Exporter;
our (@ISA, @EXPORT, @EXPORT_OK);

@ISA       = qw(Exporter);
@EXPORT    = qw(ws_send ws_send_all);
@EXPORT_OK = qw(ws_create ws_is_worker_connected);

# id->worker mapping
my $workers;

# internal helpers prototypes
sub _message;
sub _get_worker;

sub ws_send {
    my ($workerid, $msg, $jobid, $retry) = @_;
    return unless ($workerid && $msg && $workers->{$workerid});
    $jobid ||= '';
    my $res;
    my $tx = $workers->{$workerid}->{socket};
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

# consider ws_send_all as broadcast and don't wait for confirmation
sub ws_send_all {
    my ($msg) = @_;
    for my $tx (values %$workers) {
        if ($tx->{socket}) {
            $tx->{socket}->send({json => {type => $msg}});
        }
    }
}

sub check_authorized {
    my ($self)    = @_;
    my $headers   = $self->req->headers;
    my $key       = $headers->header('X-API-Key');
    my $hash      = $headers->header('X-API-Hash');
    my $timestamp = $headers->header('X-API-Microtime');
    my $user;
    log_debug($key ? "API key from client: *$key*" : "No API key from client.");

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
                    log_debug(sprintf "API auth by user: %s, operator: %d", $user->username, $user->is_operator);
                }
            }
        }
    }
    return 1 if ($user && $user->is_operator);

    $self->render(json => {error => "Not authorized"}, status => 403);
    return;
}

sub ws_create {
    my ($self) = @_;
    my $workerid = $self->param('workerid');
    unless ($workers->{$workerid}) {
        my $db = app->schema->resultset("Workers")->find($workerid);
        unless ($db) {
            return $self->render(text => 'Unauthorized', status =>);
        }
        $workers->{$workerid} = {id => $workerid, db => $db, socket => undef, last_seen => time()};
    }
    my $worker = $workers->{$workerid};
    # upgrade connection to websocket by subscribing to events
    $self->on(json   => \&_message);
    $self->on(finish => \&_finish);
    $worker->{socket} = $self->tx->max_websocket_size(10485760);
}

sub ws_is_worker_connected {
    my ($workerid) = @_;
    return ($workers->{$workerid} && $workers->{$workerid}->{socket} ? 1 : 0);
}

sub _get_worker {
    my ($tx) = @_;
    for my $worker (values %$workers) {
        if ($worker->{socket} && ($worker->{socket}->connection eq $tx->connection)) {
            return $worker;
        }
    }
    return;
}

sub _finish {
    my ($ws, $code, $reason) = @_;
    return unless ($ws);

    my $worker = _get_worker($ws->tx);
    unless ($worker) {
        log_error('Worker not found for given connection during connection close');
        return;
    }
    log_debug(sprintf("Worker %u websocket connection closed - $code", $worker->{id}));
    $worker->{socket} = undef;
}

sub _message {
    my ($ws, $json) = @_;
    my $worker = _get_worker($ws->tx);
    unless ($worker) {
        $ws->app->log->warn("A message received from unknown worker connection");
        return;
    }
    unless (ref($json) eq 'HASH') {
        use Data::Dumper;
        log_error(sprintf('Received unexpected WS message "%s from worker %u', Dumper($json), $worker->id));
        return;
    }

    $worker->{last_seen} = time();
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
            log_error("Unknown property received from worker $worker->{id}");
        }
    }
    else {
        log_error(sprintf('Received unknown message type "%s" from worker %u', $json->{type}, $worker->{id}));
    }
}

sub _get_stale_worker_jobs {
    my ($threshold) = @_;

    my $schema = OpenQA::Schema::connect_db;

    # grab the workers we've seen lately
    my @ok_workers;
    for my $worker (values %$workers) {
        if (time - $worker->{last_seen} <= $threshold) {
            push(@ok_workers, $worker->{id});
        }
        else {
            log_debug(sprintf("Worker %s not seen since %d seconds", $worker->{db}->name, time - $worker->{last_seen}));
        }
    }
    my $dtf = $schema->storage->datetime_parser;
    my $dt = DateTime->from_epoch(epoch => time() - $threshold, time_zone => 'UTC');

    my %cond = (
        state              => [OpenQA::Schema::Result::Jobs::EXECUTION_STATES],
        'worker.t_updated' => {'<' => $dtf->format_datetime($dt)},
        'worker.id'        => {-not_in => [sort @ok_workers]});
    my %attrs = (join => 'worker');

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

    log_debug(
        "job considered dead: " . $job->id . " worker " . $job->worker->id . " not seen. In state " . $job->state);
    # default timeout for the rest
    return 1;
}

# Check if worker with job has been updated recently; if not, assume it
# got stuck somehow and duplicate or incomplete the job
sub _workers_checker {

    my $threshold  = 40;
    my $stale_jobs = _get_stale_worker_jobs($threshold);
    for my $job ($stale_jobs->all) {
        next unless _is_job_considered_dead($job);

        $job->done(result => OpenQA::Schema::Result::Jobs::INCOMPLETE);
        my $res = $job->auto_duplicate;
        if ($res) {
            # do it through the DBUS signal to avoid messing with file descriptors
            notify_workers;
            log_warning(sprintf('dead job %d aborted and duplicated %d', $job->id, $res->id));
        }
        else {
            log_warning(sprintf('dead job %d aborted as incomplete', $job->id));
        }
    }
}

sub jobs_available {
    OpenQA::WebSockets::Server::ws_send_all(('job_available'));
    return;
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

    my $connect_signal;
    $connect_signal = sub {
        try {
            log_debug "connecting scheduler signal";
            OpenQA::IPC->ipc->service('scheduler')->connect_to_signal(JobsAvailable => \&jobs_available);
        }
        catch {
            log_debug "scheduler connect failed, retrying in 2 seconds";
            Mojo::IOLoop->timer(2 => $connect_signal);
        };
    };
    $connect_signal->();

    return Mojo::Server::Daemon->new(app => app, listen => ["http://localhost:$port"]);
}


1;
