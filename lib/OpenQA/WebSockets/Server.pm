# Copyright (C) 2014-2019 SUSE LLC
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
use Mojo::Base 'Mojolicious';

use Mojo::Util 'hmac_sha1_sum';
use Mojo::Server::Daemon;
use Try::Tiny;
use OpenQA::IPC;
use OpenQA::Utils qw(log_debug log_warning log_info log_error);
use OpenQA::Schema;
use OpenQA::Setup;
use Data::Dumper 'Dumper';
use Data::Dump 'pp';
use db_profiler;
use OpenQA::Schema::Result::Workers ();
use OpenQA::Constants qw(WEBSOCKET_API_VERSION WORKERS_CHECKER_THRESHOLD);

# id->worker mapping
my $workers;

# Will be filled out from worker status messages
my $worker_status;

# Mojolicious startup
sub setup {
    my $self = shift;

    $self->helper(log_name => sub { return 'websockets' });
    $self->helper(schema   => sub { return OpenQA::Schema->singleton });
    $self->defaults(appname => 'openQA Websocket Server');
    $self->mode('production');

    OpenQA::Setup::read_config($self);
    OpenQA::Setup::setup_log($self);

    push @{$self->plugins->namespaces}, 'OpenQA::WebAPI::Plugin';

    # Assetpack is required to render layouts pages
    $self->plugin(AssetPack => {pipes => [qw(Sass Css JavaScript Fetch OpenQA::WebAPI::AssetPipe Combine)]});
    $self->plugin('Helpers');
    $self->asset->process;

    my $ca = $self->routes->under(\&_check_authorized);
    $ca->websocket('/ws/:workerid' => [workerid => qr/\d+/] => \&_ws_create);

    # no cookies for worker, no secrets to protect
    $self->secrets(['nosecretshere']);

    # start worker checker - check workers each 2 minutes
    Mojo::IOLoop->recurring(120 => \&_workers_checker);

    Mojo::IOLoop->recurring(
        380 => sub {
            log_debug('Resetting worker status table');
            $worker_status = {};
        });

    return Mojo::Server::Daemon->new(app => $self);
}

sub ws_is_worker_connected {
    my ($workerid) = @_;
    return ($workers->{$workerid} && $workers->{$workerid}->{socket} ? 1 : 0);
}

sub ws_send {
    my ($workerid, $msg, $jobid, $retry) = @_;
    return unless ($workerid && $msg && $workers->{$workerid});
    $jobid ||= '';
    my $res;
    my $tx = $workers->{$workerid}->{socket};
    if ($tx) {
        $res = $tx->send({json => {type => $msg, jobid => $jobid}});
    }
    unless ($res && !$res->error) {
        $retry ||= 0;
        if ($retry < 3) {
            Mojo::IOLoop->timer(2 => sub { ws_send($workerid, $msg, $jobid, ++$retry); });
        }
        else {
            log_debug("Unable to send command \"$msg\" to worker $workerid");
        }
    }
}

sub ws_send_job {
    my ($job) = @_;
    my $result = {state => {msg_sent => 0}};

    unless (ref($job) eq 'HASH' && exists $job->{assigned_worker_id}) {
        $result->{state}->{error} = "No workerid assigned";
        return $result;
    }

    unless ($workers->{$job->{assigned_worker_id}}) {
        $result->{state}->{error}
          = "Worker " . $job->{assigned_worker_id} . " doesn't have established a ws connection";
        return $result;
    }

    my $res;
    my $tx = $workers->{$job->{assigned_worker_id}}->{socket};
    if ($tx) {
        $res = $tx->send({json => {type => 'grab_job', job => $job}});
    }
    unless ($res && !$res->error) {
        # Since it is used by scheduler, it's fine to let it fail,
        # will be rescheduled on next round
        log_debug("Unable to allocate job to worker $job->{assigned_worker_id}");
        $result->{state}->{error} = "Sending $job->{id} thru WebSockets to $job->{assigned_worker_id} failed miserably";
        $result->{state}->{res}   = $res;
        return $result;
    }
    else {
        log_debug("message sent to $job->{assigned_worker_id} for job $job->{id}");
        $result->{state}->{msg_sent} = 1;
    }
    return $result;
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

sub _check_authorized {
    my ($self) = @_;

    my $headers   = $self->req->headers;
    my $key       = $headers->header('X-API-Key');
    my $hash      = $headers->header('X-API-Hash');
    my $timestamp = $headers->header('X-API-Microtime');
    my $user;
    log_debug($key ? "API key from client: *$key*" : "No API key from client.");

    my $schema  = OpenQA::Schema->singleton;
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

    $self->render(json => {error => 'Not authorized'}, status => 403);
    return undef;
}

sub _ws_create {
    my ($c) = @_;

    my $workerid = $c->param('workerid');
    unless ($workers->{$workerid}) {
        my $db = $c->app->schema->resultset("Workers")->find($workerid);
        unless ($db) {
            return $c->render(text => 'Unauthorized', status =>);
        }
        $workers->{$workerid} = {id => $workerid, db => $db, socket => undef, last_seen => time()};
    }
    my $worker = $workers->{$workerid};

    # upgrade connection to websocket by subscribing to events
    $c->on(json   => \&_message);
    $c->on(finish => \&_finish);
    $c->inactivity_timeout(0);    # Do not force connection close due to inactivity
    $worker->{socket} = $c->tx->max_websocket_size(10485760);
}

sub _get_worker {
    my ($tx) = @_;
    for my $worker (values %$workers) {
        if ($worker->{socket} && ($worker->{socket}->connection eq $tx->connection)) {
            return $worker;
        }
    }
    return undef;
}

sub _finish {
    my ($c, $code, $reason) = @_;
    return unless ($c);

    my $worker = _get_worker($c->tx);
    unless ($worker) {
        log_error('Worker not found for given connection during connection close');
        return;
    }
    log_info(sprintf("Worker %u websocket connection closed - $code", $worker->{id}));
    # if the server disconnected from web socket, mark it dead so it doesn't get new
    # jobs assigned from scheduler (which will check DB and not WS state)
    my $dt = DateTime->now(time_zone => 'UTC');
    # 2 minutes is long enough for the scheduler not to take it
    $dt->subtract(seconds => (WORKERS_CHECKER_THRESHOLD + 20));
    $worker->{db}->update({t_updated => $dt});
    $worker->{socket} = undef;
}

sub _message {
    my ($c, $json) = @_;

    my $app    = $c->app;
    my $schema = $app->schema;
    my $worker = _get_worker($c->tx);
    unless ($worker) {
        $app->log->warn("A message received from unknown worker connection");
        log_debug(sprintf('A message received from unknown worker connection (terminating ws): %s', Dumper($json)));
        $c->finish("1008", "Connection terminated from WebSocket server - thought dead");
        return;
    }
    unless (ref($json) eq 'HASH') {
        log_error(sprintf('Received unexpected WS message "%s from worker %u', Dumper($json), $worker->{id}));
        $c->finish("1003", "Received unexpected data from worker, forcing close");
        return;
    }

    # This is to make sure that no worker can skip the _registration.
    if (($worker->{db}->websocket_api_version() || 0) != WEBSOCKET_API_VERSION) {
        log_warning("Received a message from an incompatible worker " . $worker->{id});
        $c->tx->send({json => {type => 'incompatible'}});
        $c->finish("1008", "Connection terminated from WebSocket server - incompatible communication protocol version");
        return;
    }

    $worker->{last_seen} = time();
    if ($json->{type} eq 'accepted') {
        my $jobid = $json->{jobid};
        log_debug("Worker: $worker->{id} accepted job $jobid");
    }
    elsif ($json->{type} eq 'status') {
        # handle job status update through web socket
        my $jobid  = $json->{jobid};
        my $status = $json->{data};
        my $job    = $schema->resultset("Jobs")->find($jobid);
        return $c->tx->send(json => {result => 'nack'}) unless $job;
        my $ret = $job->update_status($status);
        $c->tx->send({json => $ret});
    }
    elsif ($json->{type} eq 'worker_status') {
        my $current_worker_status = $json->{status};
        my $current_worker_error  = $current_worker_status eq 'broken' ? $json->{reason} : undef;
        my $job_status            = $json->{job}->{state};
        my $jobid                 = $json->{job}->{id};
        my $wid                   = $worker->{id};

        $worker_status->{$wid} = $json;
        log_debug(sprintf('Received from worker "%u" worker_status message "%s"', $wid, Dumper($json)));

        try {
            $schema->txn_do(
                sub {
                    return unless my $w = $schema->resultset("Workers")->find($wid);
                    log_debug("Updating worker seen from worker_status");
                    $w->seen;
                    $w->update({error => $current_worker_error});
                });
        }
        catch {
            log_error("Failed updating worker seen and error status: $_");
        };

        my $registered_job_id;
        my $registered_job_token;
        try {
            $registered_job_id = $schema->resultset("Workers")->find($wid)->job->id();
            log_debug("Found Job($registered_job_id) in DB from worker_status update sent by Worker($wid)")
              if $registered_job_id && $wid;
            log_debug("Received request has id: " . $worker_status->{$wid}->{job}->{id})
              if $worker_status->{$wid}->{job}->{id};
        };

        try {
            my $workers_population = $schema->resultset("Workers")->count();
            my $msg                = {type => 'info', population => $workers_population};
            $c->tx->send({json => $msg} => sub { log_debug("Sent population to worker: " . pp($msg)) });
        }
        catch {
            log_debug("Could not send the population number to worker: $_");
        };

        try {
            # We cover the case where id can be the same, but the token will differ.
            die "Do not check" unless ($registered_job_id);
            $registered_job_token = $schema->resultset("Workers")->find($wid)->get_property('JOBTOKEN');
            log_debug("Worker($wid) for Job($registered_job_id) has token $registered_job_token")
              if $registered_job_token && $registered_job_id && $wid;
            log_debug("Received request has token: " . $worker_status->{$wid}->{job}->{settings}->{JOBTOKEN})
              if $worker_status->{$wid}->{job}->{settings}->{JOBTOKEN};
        };

        try {
            # XXX: we should have a field in the DB as well so scheduler can allocate directly on free workers.
            $schema->txn_do(
                sub {
                    my $w = $schema->resultset("Workers")->find($wid);
                    log_debug('Possibly worker ' . $w->id() . ' should be freed.');
                    return unless ($w && $w->job);
                    return $w->job->incomplete_and_duplicate
                      if ( $w->job->result eq OpenQA::Jobs::Constants::NONE
                        && $w->job->state eq OpenQA::Jobs::Constants::RUNNING
                        && $current_worker_status eq "free");
                    return $w->job->reschedule_state
                      if ($w->job->state eq OpenQA::Jobs::Constants::ASSIGNED);    # Was a stale job
                })
              if (
                # Check if worker is doing a job for another WebUI
                (
                       $registered_job_id
                    && exists $worker_status->{$wid}
                    && exists $worker_status->{$wid}->{job}
                    && exists $worker_status->{$wid}->{job}->{id}
                    && $worker_status->{$wid}->{job}->{id} != $registered_job_id
                )
                || (   $registered_job_token
                    && exists $worker_status->{$wid}
                    && exists $worker_status->{$wid}->{job}
                    && exists $worker_status->{$wid}->{job}->{settings}->{JOBTOKEN}
                    && $worker_status->{$wid}->{job}->{settings}->{JOBTOKEN} ne $registered_job_token))
              ||
              # Or if it declares itself free.
              ($current_worker_status && $current_worker_status eq "free");

            return unless $jobid && $job_status && $job_status eq OpenQA::Jobs::Constants::RUNNING;
            $schema->txn_do(
                sub {
                    my $job = $schema->resultset("Jobs")->find($jobid);
                    return
                      if (
                        (
                            $job && (($job->state eq OpenQA::Jobs::Constants::RUNNING)
                                || ($job->result ne OpenQA::Jobs::Constants::NONE)))
                        || !$job
                      );
                    $job->set_running();
                    log_debug(sprintf('Job "%s" set to running states from ws status updates', $jobid));
                });

        }
        catch {
            log_debug("Failed parsing status message : $_");
        };

    }
    else {
        log_error(sprintf('Received unknown message type "%s" from worker %u', $json->{type}, $worker->{id}));
    }
}

sub _get_stale_worker_jobs {
    my ($threshold) = @_;

    my $schema = OpenQA::Schema->singleton;

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
    my $dt  = DateTime->from_epoch(epoch => time() - $threshold, time_zone => 'UTC');

    my %cond = (
        state              => [OpenQA::Jobs::Constants::EXECUTION_STATES],
        'worker.t_updated' => {'<' => $dtf->format_datetime($dt)},
        'worker.id'        => {-not_in => [sort @ok_workers]});
    my %attrs = (join => 'worker', order_by => 'worker.id desc');

    return $schema->resultset("Jobs")->search(\%cond, \%attrs);
}

sub _is_job_considered_dead {
    my ($job) = @_;

    # much bigger timeout for uploading jobs; while uploading files,
    # worker process is blocked and cannot send status updates
    if ($job->state eq OpenQA::Jobs::Constants::UPLOADING) {
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
    my $schema = OpenQA::Schema->singleton;
    try {
        $schema->txn_do(
            sub {
                my $stale_jobs = _get_stale_worker_jobs(WORKERS_CHECKER_THRESHOLD);
                for my $job ($stale_jobs->all) {
                    next unless _is_job_considered_dead($job);

                    $job->done(result => OpenQA::Jobs::Constants::INCOMPLETE);
                    # XXX: auto_duplicate was killing ws server in production
                    my $res = $job->auto_duplicate;
                    if ($res) {
                        log_warning(sprintf('dead job %d aborted and duplicated %d', $job->id, $res->id));
                    }
                    else {
                        log_warning(sprintf('dead job %d aborted as incomplete', $job->id));
                    }
                }
            });
    }
    catch {
        log_info("Failed dead job detection : $_");
    };
}

1;
