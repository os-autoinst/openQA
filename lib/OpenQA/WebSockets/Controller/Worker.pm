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

package OpenQA::WebSockets::Controller::Worker;
use Mojo::Base 'Mojolicious::Controller';

use OpenQA::Schema;
use OpenQA::Utils qw(log_debug log_error log_info log_warning);
use OpenQA::Constants qw(WEBSOCKET_API_VERSION WORKERS_CHECKER_THRESHOLD);
use OpenQA::WebSockets::Model::Status;
use OpenQA::Jobs::Constants;
use OpenQA::Scheduler::Client;
use DateTime;
use Data::Dump 'pp';
use Try::Tiny;
use Mojo::Util 'dumper';

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
    $reason = ($reason ? ": $reason" : '');
    log_info("Worker $worker->{id} websocket connection closed - $code$reason");

    # note: Not marking the worker immediately as offline because it is expected to reconnect if the connection
    #       is lost unexpectedly. It will be considered offline after WORKERS_CHECKER_THRESHOLD seconds.
}

sub _message {
    my ($self, $json) = @_;

    my $app           = $self->app;
    my $schema        = $app->schema;
    my $worker_status = $app->status->worker_status;

    # find relevant worker
    my $worker = OpenQA::WebSockets::Model::Status->singleton->worker_by_transaction->{$self->tx};
    unless ($worker) {
        $app->log->warn("A message received from unknown worker connection");
        log_debug(sprintf('A message received from unknown worker connection (terminating ws): %s', dumper($json)));
        $self->finish("1008", "Connection terminated from WebSocket server - thought dead");
        return undef;
    }
    my $worker_id = $worker->{id};
    my $worker_db = $worker->{db};

    unless (ref($json) eq 'HASH') {
        log_error(sprintf('Received unexpected WS message "%s from worker %u', dumper($json), $worker_id));
        $self->finish(1003 => 'Received unexpected data from worker, forcing close');
        return undef;
    }

    # make sure no worker can skip the initial registration
    if (($worker_db->websocket_api_version || 0) != WEBSOCKET_API_VERSION) {
        log_warning("Received a message from an incompatible worker $worker_id");
        $self->send({json => {type => 'incompatible'}});
        $self->finish(
            1008 => 'Connection terminated from WebSocket server - incompatible communication protocol version');
        return undef;
    }

    my $message_type = $json->{type};
    if ($message_type eq 'quit') {
        my $dt = DateTime->now(time_zone => 'UTC');
        $dt->subtract(seconds => WORKERS_CHECKER_THRESHOLD);
        $worker_db->update({t_updated => $dt});
        $worker_db->reschedule_assigned_jobs;
    }
    elsif ($message_type eq 'rejected') {
        my $job_ids = $json->{job_ids};
        my $reason  = $json->{reason} // 'unknown reason';
        return undef unless ref($job_ids) eq 'ARRAY' && @$job_ids;

        my $job_ids_str = join(', ', @$job_ids);
        log_debug("Worker $worker_id rejected job(s) $job_ids_str: $reason");

        # re-schedule rejected job if it is still assigned to that worker
        try {
            $schema->txn_do(
                sub {
                    my @jobs = $schema->resultset('Jobs')
                      ->search({id => {-in => $job_ids}, assigned_worker_id => $worker_id, state => ASSIGNED});
                    $_->reschedule_state for @jobs;
                });
        }
        catch {
            log_warning("Unable to re-schedule job(s) $job_ids_str rejected by worker $worker_id: $_");
        };
    }
    elsif ($message_type eq 'accepted') {
        my $job_id = $json->{jobid};
        return undef unless $job_id;

        # verify whether the job has previously been assigned to the worker and can actually be accepted
        my $job = $worker_db->unfinished_jobs->find($job_id);
        if (!$job) {
            log_warning(
                "Worker $worker_id accepted job $job_id which was never assigned to it or has already finished");
            return undef;
        }

        # assume the job setup is done by the worker
        $schema->resultset('Jobs')->search({id => $job_id, state => ASSIGNED, t_finished => undef})
          ->update({state => SETUP});

        # update the worker's current job
        $worker_db->update({job_id => $job_id});
        log_debug("Worker $worker_id accepted job $job_id");
    }
    elsif ($message_type eq 'worker_status') {
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
        log_debug(sprintf('Received from worker "%u" worker_status message "%s"', $wid, dumper($json)));

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
    }
    else {
        log_error(sprintf('Received unknown message type "%s" from worker %u', $message_type, $worker->{id}));
    }
}

1;
