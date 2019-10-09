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
use OpenQA::Jobs::Constants;
use OpenQA::Scheduler::Client;
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

    # mark worker as dead in the database so it doesn't get new jobs assigned from scheduler and
    # appears as offline in the web UI
    my $dt = DateTime->now(time_zone => 'UTC');
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

    if ($json->{type} eq 'accepted') {
        my $job_id = $json->{jobid};
        return undef unless $job_id;

        # verify whether the job has previously been assigned to the worker and can actually be accepted
        my $job = $worker->{db}->unfinished_jobs->find($job_id);
        if (!$job) {
            log_warning(
                "Worker $worker->{id} accepted job $job_id which was never assigned to it or has already finished");
            return undef;
        }

        # update the worker's current job
        $worker->{db}->update({job_id => $job_id});
        log_debug("Worker $worker->{id} accepted job $job_id");
    }
    elsif ($json->{type} eq 'worker_status') {
        my $current_worker_status = $json->{status};
        my $current_worker_error  = $current_worker_status eq 'broken' ? $json->{reason} : undef;
        my $job_info              = $json->{job} // {};
        my $job_status            = $job_info->{state};
        my $job_id                = $job_info->{id};
        my $job_settings          = $job_info->{settings} // {};
        my $job_token             = $job_settings->{JOBTOKEN};
        my $pending_job_ids       = $json->{pending_job_ids} // {};
        my $wid                   = $worker->{id};

        $worker_status->{$wid} = $json;
        log_debug(sprintf('Received from worker "%u" worker_status message "%s"', $wid, Dumper($json)));

        # log that we 'saw' the worker
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

        # send worker population
        try {
            my $workers_population = $schema->resultset("Workers")->count();
            my $msg                = {type => 'info', population => $workers_population};
            $self->tx->send({json => $msg} => sub { log_debug("Sent population to worker: " . pp($msg)) });
        }
        catch {
            log_debug("Could not send the population number to worker: $_");
        };

        # find the job currently associated with that worker
        my $registered_job_id;
        my $registered_job_token;
        my $registered_job_state;
        try {
            return undef unless defined $wid;
            my $worker = $schema->resultset('Workers')->find($wid);
            return undef unless $worker;

            my $registered_job = $worker->job;
            if ($registered_job) {
                $registered_job_id    = $registered_job->id;
                $registered_job_state = $registered_job->state;
            }
            log_debug("Found job $registered_job_id in DB from worker_status update sent by worker $wid")
              if defined $registered_job_id;
            log_debug("Received request has job id: $job_id")
              if defined $job_id;

            $registered_job_token = $worker->get_property('JOBTOKEN');
            log_debug("Worker $wid for job $registered_job_id has token $registered_job_token")
              if defined $registered_job_id && defined $registered_job_token;
            log_debug("Received request has token: $job_token")
              if defined $job_token;
        };

        # skip informing scheduler if worker just does the job we expected it to do
        return undef
          if ( defined $job_id
            && defined $registered_job_id
            && defined $job_token
            && defined $registered_job_token
            && $job_id eq $registered_job_id
            && $job_token eq $registered_job_token
            && $registered_job_state eq RUNNING);

        # skip informing scheduler if worker is idling as expected
        return undef if (!defined $job_id && !defined $registered_job_id);

        # let the scheduler know so it can update the status of related jobs according to what the worker reported
        OpenQA::Scheduler::Client->singleton->inform_scheduler_that_worker_reported_back(
            {
                worker_id          => $wid,
                worker_status      => $current_worker_status,
                current_job_id     => $job_id,
                current_job_status => $job_status,
                pending_job_ids    => $pending_job_ids,
                job_token          => $job_token,
            },
            sub {
                my ($ua, $tx) = @_;
                my $err = $tx->error;
                return unless $err;

                my $message
                  = $err->{code}
                  ? "$err->{code} response: $err->{message}"
                  : "connection error: $err->{message}";
                log_error("Unable to inform scheduler that worker $wid reported back ($message)");
                if (my $res = $tx->res) { log_error('response was: ' . $res->body); }
            });
    }
    else {
        log_error(sprintf('Received unknown message type "%s" from worker %u', $json->{type}, $worker->{id}));
    }
}

1;
