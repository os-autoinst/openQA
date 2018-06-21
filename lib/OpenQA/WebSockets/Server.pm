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
use Cpanel::JSON::XS;
use Mojolicious::Lite;
use Mojo::Util 'hmac_sha1_sum';
use Try::Tiny;

use OpenQA::IPC;
use OpenQA::Utils qw(log_debug log_warning log_error);
use OpenQA::Schema;
use OpenQA::Setup;
use Data::Dumper;
use Data::Dump 'pp';
use db_profiler;
use OpenQA::Schema::Result::Workers ();
use OpenQA::Constants qw(WEBSOCKET_API_VERSION WORKERS_CHECKER_THRESHOLD);

require Exporter;
our (@ISA, @EXPORT, @EXPORT_OK);

@ISA       = qw(Exporter);
@EXPORT    = qw(ws_send ws_send_all ws_send_job);
@EXPORT_OK = qw(ws_create ws_is_worker_connected);

# id->worker mapping
my $workers;

# Will be filled out from worker status messages
my $worker_status;

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

sub ws_send_job {
    my ($job) = @_;
    my $result = {state => {msg_sent => 0}};

    unless (ref($job) eq "HASH" && exists $job->{assigned_worker_id}) {
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
    unless ($res && $res->success) {
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
    $self->inactivity_timeout(0);    # Do not force connection close due to inactivity
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
    # if the server disconnected from web socket, mark it dead so it doesn't get new
    # jobs assigned from scheduler (which will check DB and not WS state)
    my $dt = DateTime->now(time_zone => 'UTC');
    # 2 minutes is long enough for the scheduler not to take it
    $dt->subtract(seconds => (WORKERS_CHECKER_THRESHOLD + 20));
    $worker->{db}->update({t_updated => $dt});
    $worker->{socket} = undef;
}

sub _message {
    my ($ws, $json) = @_;
    my $worker = _get_worker($ws->tx);
    unless ($worker) {
        $ws->app->log->warn("A message received from unknown worker connection");
        log_debug(sprintf('A message received from unknown worker connection (terminating ws): %s', Dumper($json)));
        $ws->finish("1008", "Connection terminated from WebSocket server - thought dead");
        return;
    }
    unless (ref($json) eq 'HASH') {
        log_error(sprintf('Received unexpected WS message "%s from worker %u', Dumper($json), $worker->{id}));
        $ws->finish("1003", "Received unexpected data from worker, forcing close");
        return;
    }

    # This is to make sure that no worker can skip the _registration.
    if (($worker->{db}->get_websocket_api_version() || 0) != WEBSOCKET_API_VERSION) {
        log_warning("Received a message from an incompatible worker " . $worker->{id});
        $ws->tx->send({json => {type => 'incompatible'}});
        $ws->finish("1008",
            "Connection terminated from WebSocket server - incompatible communication protocol version");
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
        my $job    = $ws->app->schema->resultset("Jobs")->find($jobid);
        return $ws->tx->send(json => {result => 'nack'}) unless $job;
        my $ret = $job->update_status($status);
        $ws->tx->send({json => $ret});
    }
    elsif ($json->{type} eq 'worker_status') {
        my $current_worker_status = $json->{status};
        my $job_status            = $json->{job}->{state};
        my $jobid                 = $json->{job}->{id};
        my $wid                   = $worker->{id};

        $worker_status->{$wid} = $json;
        log_debug(sprintf('Received from worker "%u" worker_status message "%s"', $wid, Dumper($json)));

        try {
            app->schema->txn_do(
                sub {
                    my $w = app->schema->resultset("Workers")->find($wid);
                    return unless $w;
                    log_debug("Updated worker seen from worker_status");
                    $w->seen;
                });
        }
        catch {
            log_error("Failed updating worker seen status: $_");
        };

        my $registered_job_id;
        my $registered_job_token;
        try {
            $registered_job_id = app->schema->resultset("Workers")->find($wid)->job->id();
            log_debug("Found Job($registered_job_id) in DB from worker_status update sent by Worker($wid)")
              if $registered_job_id && $wid;
            log_debug("Received request has id: " . $worker_status->{$wid}->{job}->{id})
              if $worker_status->{$wid}->{job}->{id};
        };

        try {
            my $workers_population = app->schema->resultset("Workers")->count();
            my $msg = {type => 'info', population => $workers_population};
            $ws->tx->send({json => $msg} => sub { log_debug("Sent population to worker: " . pp($msg)) });
        }
        catch {
            log_debug("Could not be able to send population number to worker: $_");
        };

        try {
            # We cover the case where id can be the same, but the token will differ.
            die "Do not check" unless ($registered_job_id);
            $registered_job_token = app->schema->resultset("Workers")->find($wid)->get_property('JOBTOKEN');
            log_debug("Worker($wid) for Job($registered_job_id) has token $registered_job_token")
              if $registered_job_token && $registered_job_id && $wid;
            log_debug("Received request has token: " . $worker_status->{$wid}->{job}->{settings}->{JOBTOKEN})
              if $worker_status->{$wid}->{job}->{settings}->{JOBTOKEN};
        };

        try {
            # XXX: we should have a field in the DB as well so scheduler can allocate directly on free workers.
            app->schema->txn_do(
                sub {
                    my $w = app->schema->resultset("Workers")->find($wid);
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
            app->schema->txn_do(
                sub {
                    my $job = app->schema->resultset("Jobs")->find($jobid);
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
    my $schema = OpenQA::Schema::connect_db;
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
        log_debug("Failed dead job detection : $_");
    };


   # XXX: We might need the following check in the future
   #     try {
   #         $schema->txn_do(
   #             sub {
   #                 # XXX: not needed as for now - check all job in running state with statuses received by the workers
   #                 my @running_jobs
   #                   = OpenQA::Schema::connect_db->resultset("Jobs")
   #                   ->search({state => OpenQA::Jobs::Constants::RUNNING}, {join => 'worker'})->all();
   #                 # If there is neither a worker assigned or we have a mismatch from the statuses
   #                 # received by the workers we set it as incomplete and duplicate it
   #                 foreach my $j (@running_jobs) {
   #                     if (
   #                         !$j->worker
   #                         || (   exists $worker_status->{$j->worker->id()}
   #                             && exists $worker_status->{$j->worker->id()}->{job}
   #                             && exists $worker_status->{$j->worker->id()}->{job}->{id}
   #                             && $worker_status->{$j->worker->id()}->{job}->{id} != $j->id)
   #                         || (   exists $worker_status->{$j->worker->id()}
   #                             && exists $worker_status->{$j->worker->id()}->{status}
   #                             && $worker_status->{$j->worker->id()}->{status} eq "free"))
   #                     {
   #                         log_warning(sprintf('Stale running job %d detected', $j->id));
   #                         $j->done(result => OpenQA::Jobs::Constants::INCOMPLETE);
   #                         my $res = $j->auto_duplicate;
   #                         if ($res) {
   #                             log_warning(
   #                                 sprintf(
   # 'running job %d with no worker or worker mismatching id aborted and duplicated to job "%d"',
   #                                     $j->id, $res->id
   #                                 ));
   #                         }
   #                         else {
   #                             log_warning(sprintf('running job %d aborted as incomplete', $j->id));
   #                         }
   #                     }
   #                 }
   #             });
   #     }
   #     catch {
   #         log_debug("Failed stale running job detection : $_");
   #     };
}

# Mojolicious startup
sub setup {


    app->helper(log_name => sub { return 'websockets' });
    app->helper(schema   => sub { return OpenQA::Schema::connect_db; });
    app->defaults(appname => "openQA Websocket Server");
    app->mode('production');

    OpenQA::Setup::read_config(app);
    OpenQA::Setup::setup_log(app);

    push @{app->plugins->namespaces}, 'OpenQA::WebAPI::Plugin';

    # Assetpack is required to render layouts pages.
    app->plugin(AssetPack => {pipes => [qw(Sass Css JavaScript Fetch OpenQA::WebAPI::AssetPipe Combine)]});
    app->plugin("Helpers");
    app->asset->process;

    # use port one higher than WebAPI
    my $listen = $ENV{MOJO_LISTEN} || "http://localhost:9527";

    my $ca = under \&check_authorized;
    $ca->websocket('/ws/:workerid' => [workerid => qr/\d+/] => \&ws_create);

    # no cookies for worker, no secrets to protect
    app->secrets(['nosecretshere']);

    # start worker checker - check workers each 2 minutes
    Mojo::IOLoop->recurring(120 => \&_workers_checker);

    Mojo::IOLoop->recurring(
        380 => sub {
            log_debug("Resetting worker status table");
            $worker_status = {};
        });


    return Mojo::Server::Daemon->new(app => app, listen => ["$listen"]);
}


1;
