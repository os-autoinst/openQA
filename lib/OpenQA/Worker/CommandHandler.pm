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

package OpenQA::Worker::CommandHandler;
use Mojo::Base 'Mojo::EventEmitter';

use OpenQA::Utils qw(log_error log_debug log_warning log_info);

use POSIX ':sys_wait_h';
use Data::Dump 'pp';

has 'client';

sub new {
    my ($class, $client) = @_;

    return $class->SUPER::new(client => $client);
}

sub handle_command {
    my ($self, $tx, $json) = @_;

    my $client             = $self->client;
    my $worker             = $client->worker;
    my $current_job        = $worker->current_job;
    my $webui_host         = $client->webui_host;
    my $current_webui_host = $worker->current_webui_host // 'unknown web UI host';

    # ignore responses to our own messages which are indicated by 'result'
    return undef if ($json->{result});

    # handle commands of certain types regarding a specific job (which is supposed to be the job we're working on)
    my $type = $json->{type};
    if (!$type) {
        log_warning("Ignoring WS message without type from $webui_host:\n" . pp($json));
        return undef;
    }

    # require a job ID and ensure it matches the current job if we're already executing one
    my $job_id = $json->{jobid};
    if ($type ne 'info') {
        if ($current_job) {
            # ignore messages which do not belong to the current job
            my $current_job_id = $current_job->id // 'another job';
            if (!$job_id) {
                # log a more specific warning in case of the grab_job message from a different web UI
                if ($type eq 'grab_job' && $webui_host ne $current_webui_host) {
                    log_warning("Ignoring job assignment from $webui_host "
                          . "(already busy with job $current_job_id from $current_webui_host).");
                    return undef;
                }
                log_warning("Ignoring WS message from $webui_host with type $type but no job ID "
                      . "(currently running $current_job_id for $current_webui_host):\n"
                      . pp($json));
                return undef;
            }
            if ($job_id ne $current_job_id) {
                log_warning("Ignoring WS message from $webui_host for job $job_id because that job is "
                      . "not running (running $current_job_id for $current_webui_host instead):\n"
                      . pp($json));
                return undef;
            }
        }
        else {
            # ignore messages which belong to a job
            if ($job_id) {
                log_warning("Ignoring WS message from $webui_host with type $type and job ID $job_id "
                      . "(currently not executing a job):\n"
                      . pp($json));
                return undef;
            }
        }
        # verify that the web UI host for the job ID matches as well
        if ($job_id && $webui_host ne $current_webui_host) {
            log_warning(
                "Ignoring job-specific WS message from $webui_host; currently occupied by $current_webui_host:\n"
                  . pp($json));
            return undef;
        }
    }

    if (my $handler = $self->can('_handle_command_' . $type)) {
        return $handler->($json, $client, $worker, $webui_host, $current_job);
    }
    if ($type =~ m/quit|abort|cancel|obsolete/) {
        return log_warning("Ignoring command $type without job ID.") unless $job_id;
        return $current_job->stop($type);
    }
    log_warning("Ignoring WS message with unknown type $type from $webui_host:\n" . pp($json));
}

sub _handle_command_info {
    my ($json, $client, $worker, $webui_host) = @_;

    if (my $population = $json->{population}) {
        $client->webui_host_population($population);
    }

    # enfore recalculation of interval for overall worker status update
    $client->send_status_interval(undef);
}

sub _handle_command_livelog_start {
    my ($json, $client, $worker, $webui_host, $current_job) = @_;

    $current_job->start_livelog();
}

sub _handle_command_livelog_stop {
    my ($json, $client, $worker, $webui_host, $current_job) = @_;

    $current_job->stop_livelog();
}

sub _handle_command_developer_session_start {
    my ($json, $client, $worker, $webui_host, $current_job) = @_;

    $current_job->developer_session_running(1);
}

sub _handle_command_grab_job {
    my ($json, $client, $worker, $webui_host, $current_job) = @_;

    # refuse new if worker is in error state (this will leave the job to be grabbed in assigned state)
    if (my $current_error = $worker->current_error) {
        log_debug("Refusing 'grab_job', we are currently unable to do any work: $current_error");
        return undef;
    }

    my $job_info = $json->{job};
    if (!$job_info || ref($job_info) ne 'HASH' || !defined $job_info->{id} || !$job_info->{settings}) {
        log_error("Refusing to grab job from $webui_host because the provided job is invalid: " . pp($job_info));
        return undef;
    }

    if ($current_job) {
        my $current_job_id     = $current_job->id // 'another job';
        my $current_webui_host = $worker->current_webui_host;
        log_warning(
            "Refusing to grab job from $webui_host, already busy with $current_job_id from $current_webui_host");
        return undef;
    }

    $worker->accept_job($client, $job_info);
}

sub _handle_command_incompatible {
    my ($json, $client, $worker, $webui_host, $current_job) = @_;

    # FIXME: This handler has been copied as-is when refactoring. It would make more sense to disable
    #        only the particular web UI host which is incompatible instead of just stopping everything.
    log_error("The worker is running a version incompatible with web UI host $webui_host and therefore stopped");
    Mojo::IOLoop->singleton->stop_gracefully;
}

1;
