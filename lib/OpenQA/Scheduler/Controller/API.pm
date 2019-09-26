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

package OpenQA::Scheduler::Controller::API;
use Mojo::Base 'Mojolicious::Controller';

use OpenQA::Schema;
use OpenQA::Jobs::Constants;
use OpenQA::Utils qw(log_info log_warning);
use Scalar::Util 'looks_like_number';
use Try::Tiny;

sub wakeup {
    my $self = shift;
    OpenQA::Scheduler::wakeup();
    $self->render(text => 'ok');
}

sub handle_worker_reported_back {
    my $self = shift;

    # get and validate IDs from JSON
    my $json = $self->req->json;
    return $self->render(text => 'no JSON with worker and job IDs submitted', status => 400)
      unless ref($json) eq 'HASH';
    my $worker_id = $json->{worker_id};
    return $self->render(text => 'worker ID is missing/invalid', status => 400)
      unless defined $worker_id && looks_like_number($worker_id);
    my $worker_status      = $json->{worker_status}      // '';
    my $current_job_id     = $json->{current_job_id}     // '';
    my $current_job_status = $json->{current_job_status} // '';
    my $pending_job_ids    = $json->{pending_job_ids}    // {};
    my $job_token          = $json->{job_token}          // '';

    # ensure the worker's current job is considered running
    # note: Not sure whether this is actually required. Just moving the code from the web socket server here for now.
    my $schema = OpenQA::Schema->singleton;
    if (   looks_like_number($current_job_id)
        && defined $current_job_status
        && $current_job_status eq OpenQA::Jobs::Constants::RUNNING)
    {
        try {
            $schema->txn_do(
                sub {
                    my $job = $schema->resultset('Jobs')->find($current_job_id);
                    return undef unless $job;
                    return undef if $job->state eq RUNNING || $job->result ne NONE;
                    $job->set_running;
                    log_debug("Job $current_job_id set to running when worker reported back.");
                });
        }
        catch {
            log_warning(
                "Unable to set the status of the current job $current_job_id of worker $worker_id to running: $_");
        };
    }

# set status of unfinished jobs according to what the worker has reported (e.g. if worker says it is idling we want to set
# the job it was supposed to run to "incomplete" and duplicate it)
    try {
        $schema->txn_do(
            sub {
                my $worker = $schema->resultset('Workers')->find($worker_id);
                return undef unless $worker;

                my $supposed_job_token = $worker->get_property('JOBTOKEN');
                my $job_token_correct  = $job_token eq $supposed_job_token;

                # take any unfinished jobs of that worker into account
                for my $job ($worker->unfinished_jobs) {
                    my $job_id = $job->id;

                    if ($job_token_correct) {
                        # do nothing if the worker claims that it is still working on that job
                        next if $job_id eq $current_job_id;

                        # do nothing if the worker claims that the job is still pending
                        next if exists $pending_job_ids->{$job->id};
                    }

                    # set jobs which were only assigned anyways back to scheduled
                    my $job_state = $job->state;
                    return $job->reschedule_state
                      if $job_state eq OpenQA::Jobs::Constants::ASSIGNED;

                    # mark jobs which were already beyond assigned as incomplete and duplicate it
                    return $job->incomplete_and_duplicate
                      if $job_state eq OpenQA::Jobs::Constants::RUNNING
                      || $job_state eq OpenQA::Jobs::Constants::UPLOADING
                      || $job_state eq OpenQA::Jobs::Constants::SETUP;
                }
            });
    }
    catch {
        log_warning("Unable to incomplete/duplicate or reschedule jobs abandoned by worker $worker_id: $_");
    };

    $self->render(text => 'ok');
}

1;
