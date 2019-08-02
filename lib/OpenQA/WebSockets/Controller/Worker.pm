# Copyright (C) 2019 SUSE LLC
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

package OpenQA::WebSockets::Controller::Worker;
use Mojo::Base 'Mojolicious::Controller';

use OpenQA::Schema;
use OpenQA::Utils qw(log_debug log_error log_info log_warning);
use OpenQA::Constants qw(WEBSOCKET_API_VERSION WORKERS_CHECKER_THRESHOLD);
use OpenQA::WebSockets::Model::Status;
use DateTime;
use Data::Dumper 'Dumper';
use Data::Dump 'pp';
use Try::Tiny;

sub ws {
    my ($self)      = @_;
    my $status      = $self->status;
    my $transaction = $self->tx;

    # add worker connection
    my $worker_id = $self->param('workerid');
    return $self->render(text => 'No worker ID', status => 400) unless $worker_id;
    my $worker = $status->add_worker_connection($worker_id, $transaction);
    return $self->render(text => 'Unknown worker', status => 400) unless $worker;

    # upgrade connection to websocket by subscribing to events
    $self->on(json   => \&_message);
    $self->on(finish => \&_finish);
    $self->inactivity_timeout(0);    # Do not force connection close due to inactivity
    $transaction->max_websocket_size(10485760);
}

sub _finish {
    my ($self, $code, $reason) = @_;
    return undef unless $self;

    my $worker = OpenQA::WebSockets::Model::Status->singleton->remove_worker_connection($self->tx);
    unless ($worker) {
        log_error('Worker not found for given connection during connection close');
        return undef;
    }
    log_info(sprintf("Worker %u websocket connection closed - $code", $worker->{id}));

    # if the worker disconnected from web socket, mark it dead so it doesn't get new
    # jobs assigned from scheduler (which will check DB and not WS state)
    my $dt = DateTime->now(time_zone => 'UTC');
    # 2 minutes is long enough for the scheduler not to take it
    $dt->subtract(seconds => (WORKERS_CHECKER_THRESHOLD + 20));
    $worker->{db}->update({t_updated => $dt});
}

sub _message {
    my ($self, $json) = @_;

    my $app           = $self->app;
    my $schema        = $app->schema;
    my $worker_status = $app->status->worker_status;

    my $worker = OpenQA::WebSockets::Model::Status->singleton->worker_by_transaction->{$self->tx};
    unless ($worker) {
        $app->log->warn("A message received from unknown worker connection");
        log_debug(sprintf('A message received from unknown worker connection (terminating ws): %s', Dumper($json)));
        $self->finish("1008", "Connection terminated from WebSocket server - thought dead");
        return undef;
    }
    unless (ref($json) eq 'HASH') {
        log_error(sprintf('Received unexpected WS message "%s from worker %u', Dumper($json), $worker->{id}));
        $self->finish("1003", "Received unexpected data from worker, forcing close");
        return undef;
    }

    # This is to make sure that no worker can skip the _registration.
    if (($worker->{db}->websocket_api_version() || 0) != WEBSOCKET_API_VERSION) {
        log_warning("Received a message from an incompatible worker " . $worker->{id});
        $self->tx->send({json => {type => 'incompatible'}});
        $self->finish("1008",
            "Connection terminated from WebSocket server - incompatible communication protocol version");
        return undef;
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
        return $self->tx->send({json => {result => 'nack'}}) unless $job;
        my $ret = $job->update_status($status);
        $self->tx->send({json => $ret});
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
                    return undef unless my $w = $schema->resultset("Workers")->find($wid);
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
            log_debug("Received request has id: " . $worker_status->{$wid}{job}{id})
              if $worker_status->{$wid}{job}{id};
        };

        try {
            my $workers_population = $schema->resultset("Workers")->count();
            my $msg                = {type => 'info', population => $workers_population};
            $self->tx->send({json => $msg} => sub { log_debug("Sent population to worker: " . pp($msg)) });
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
            log_debug("Received request has token: " . $worker_status->{$wid}{job}{settings}{JOBTOKEN})
              if $worker_status->{$wid}{job}{settings}{JOBTOKEN};
        };

        try {
            # XXX: we should have a field in the DB as well so scheduler can allocate directly on free workers.
            $schema->txn_do(
                sub {
                    my $w = $schema->resultset("Workers")->find($wid);
                    log_debug('Possibly worker ' . $w->id() . ' should be freed.');
                    return undef unless ($w && $w->job);
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
                    && exists $worker_status->{$wid}{job}
                    && exists $worker_status->{$wid}{job}{id}
                    && $worker_status->{$wid}{job}{id} != $registered_job_id
                )
                || (   $registered_job_token
                    && exists $worker_status->{$wid}
                    && exists $worker_status->{$wid}{job}
                    && exists $worker_status->{$wid}{job}{settings}{JOBTOKEN}
                    && $worker_status->{$wid}{job}{settings}{JOBTOKEN} ne $registered_job_token))
              ||
              # Or if it declares itself free.
              ($current_worker_status && $current_worker_status eq "free");

            return undef unless $jobid && $job_status && $job_status eq OpenQA::Jobs::Constants::RUNNING;
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

1;
