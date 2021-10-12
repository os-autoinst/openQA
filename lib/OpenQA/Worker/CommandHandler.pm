# Copyright 2019-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Worker::CommandHandler;
use Mojo::Base 'Mojo::EventEmitter';

use OpenQA::Constants qw(WORKER_STOP_COMMANDS WORKER_LIVE_COMMANDS);
use OpenQA::Log qw(log_error log_debug log_warning log_info);

use POSIX ':sys_wait_h';
use Data::Dump 'pp';

has 'client';

my %STOP_COMMANDS = map { ($_ => 1) } WORKER_STOP_COMMANDS;
my %COMMANDS_SPECIFIC_TO_CURRENT_JOB = map { ($_ => 1) } WORKER_LIVE_COMMANDS;

sub new {
    my ($class, $client) = @_;

    return $class->SUPER::new(client => $client);
}

sub handle_command {
    my ($self, $tx, $json) = @_;

    my $client = $self->client;
    my $worker = $client->worker;
    my $current_job = $worker->current_job;
    my $webui_host = $client->webui_host;
    my $current_webui_host = $worker->current_webui_host // 'unknown web UI host';

    return log_warning("Ignoring invalid json sent by $current_webui_host") unless ref($json) eq 'HASH';

    # ignore responses to our own messages which are indicated by 'result'
    return undef if defined $json->{result};

    # handle commands of certain types regarding a specific job (which is supposed to be the job we're working on)
    my $type = $json->{type};
    return log_warning("Ignoring WS message without type from $webui_host:\n" . pp($json)) unless defined $type;

    # match the specified job
    my $job_id = $json->{jobid};
    my $is_stop_type = exists $STOP_COMMANDS{$type};
    my $relevant_job;
    if ($is_stop_type) {
        if ($webui_host ne $current_webui_host) {
            log_warning("Ignoring job cancel from $webui_host (currently working for $current_webui_host).");
            return undef;
        }
        # require a job ID and ensure it matches one of the current jobs
        if (!$job_id) {
            log_warning("Ignoring job cancel from $webui_host because no job ID was given.");
            return undef;
        }
        if (!($relevant_job = $worker->find_current_or_pending_job($job_id))) {
            log_warning("Ignoring job cancel from $webui_host because there's no job with ID $job_id.");
            return undef;
        }
    }
    elsif (exists $COMMANDS_SPECIFIC_TO_CURRENT_JOB{$type}) {
        # require a job ID and ensure it matches the current job if we're already executing one
        if ($current_job) {
            # ignore messages which do not belong to the current job
            my $current_job_id = $current_job->id // 'another job';
            if (!defined $job_id) {
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
            if (defined $job_id) {
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
    if ($is_stop_type) {
        return log_warning("Ignoring command $type without job ID.") unless $job_id;

        my $current_job = $worker->current_job;
        if ($current_job && $current_job == $relevant_job) {
            return $current_job->stop($type);
        }
        else {
            log_info("Will $type job $job_id later as requested by the web UI");
            return $worker->skip_job($job_id, $type);
        }
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

sub _can_grab_job {
    my ($client, $worker, $webui_host, $current_job, $job_ids_to_grab) = @_;
    my $reason_to_reject_job;

    # refuse new job(s) if the worker is
    # * in an error state
    # * stopping
    if ($worker->is_stopping) {
        $reason_to_reject_job = 'currently stopping';
        # note: Not rejecting the job here; declaring the worker as offline which is done in any case
        #       should be sufficient.
    }
    elsif (my $current_error = $worker->current_error) {
        $reason_to_reject_job = $current_error;
        $client->reject_jobs($job_ids_to_grab, $reason_to_reject_job);
    }
    if (defined $reason_to_reject_job) {
        log_debug("Refusing to grab job from $webui_host: $reason_to_reject_job");
        return 0;
    }

    # no reason to reject the job(s) if idling
    return 1 unless $worker->is_busy;

    # set reason to reject the job(s) if the worker is already busy with *different* jobs
    my $current_webui_host = $worker->current_webui_host;
    if (defined $current_webui_host && $current_webui_host ne $webui_host) {
        $reason_to_reject_job = "already busy with a job from $current_webui_host";
    }
    else {
        for my $job_id_to_grab (@$job_ids_to_grab) {
            next if $worker->find_current_or_pending_job($job_id_to_grab);
            $reason_to_reject_job = 'already busy with job(s) ' . join(', ', @{$worker->current_job_ids});
            last;
        }
    }

    # ignore grab job message if the worker is already busy with these job(s)
    # note: Likely the web socket server sent the grab_job message twice because the worker
    #       sent an "idle" status before processing the initial grab_job message.
    return 0 unless defined $reason_to_reject_job;

    # reject jobs otherwise
    $client->reject_jobs($job_ids_to_grab, $reason_to_reject_job);
    log_warning("Refusing to grab job from $webui_host: $reason_to_reject_job");
    return 0;
}

sub _can_accept_job {
    my ($client, $webui_host, $job_info, $job_ids_to_grab) = @_;

    my $job_id_missing = ref($job_info) ne 'HASH' || !defined $job_info->{id};
    if ($job_id_missing || !$job_info->{settings}) {
        $client->reject_jobs($job_ids_to_grab // [$job_info->{id}], 'the provided job is invalid')
          if defined $job_ids_to_grab || !$job_id_missing;
        log_error("Refusing to grab job from $webui_host: the provided job is invalid: " . pp($job_info));
        return undef;
    }

    return $job_info->{id};
}

sub _can_accept_sequence {
    my ($client, $webui_host, $job_sequence, $job_data, $job_ids_to_grab) = @_;

    for my $job_id_or_sub_sequence (@$job_sequence) {
        $job_id_or_sub_sequence //= '?';
        if (ref($job_id_or_sub_sequence) eq 'ARRAY') {
            return 0 unless _can_accept_sequence($client, $webui_host, $job_id_or_sub_sequence, $job_data);
        }
        elsif (!exists $job_data->{$job_id_or_sub_sequence}) {
            my $reason_to_reject_job = "job data for job $job_id_or_sub_sequence is missing";
            $client->reject_jobs($job_ids_to_grab, $reason_to_reject_job);
            log_error("Refusing to grab job from $webui_host: $reason_to_reject_job");
            return 0;
        }
    }
    return 1;
}

sub _handle_command_grab_job {
    my ($json, $client, $worker, $webui_host, $current_job) = @_;

    my $job_info = $json->{job};
    my $job_id = _can_accept_job($client, $webui_host, $job_info);
    return undef unless defined $job_id;
    return undef unless _can_grab_job($client, $worker, $webui_host, $current_job, [$job_id]);

    $worker->accept_job($client, $job_info);
}

sub _handle_command_grab_jobs {
    my ($json, $client, $worker, $webui_host, $current_job) = @_;

    # validate input (log error and ignore job on failure)
    my $job_info = $json->{job_info} // {};
    my $job_data = $job_info->{data};
    my $job_sequence = $job_info->{sequence};
    if (ref($job_data) ne 'HASH') {
        log_error(
            "Refusing to grab jobs from $webui_host: the provided job info lacks job data or execution sequence: "
              . pp($job_info));
        return undef;
    }
    my @job_ids_to_grab = keys %$job_data;
    if (ref($job_sequence) ne 'ARRAY') {
        log_error(
            "Refusing to grab jobs from $webui_host: the provided job info lacks execution sequence: " . pp($job_info));
        $client->reject_jobs(\@job_ids_to_grab, 'job info lacks execution sequence');
        return undef;
    }
    for my $job_id (@job_ids_to_grab) {
        my $acceptable_id = _can_accept_job($client, $webui_host, $job_data->{$job_id}, \@job_ids_to_grab);
        return undef unless defined $acceptable_id && $acceptable_id eq $job_id;
    }
    return undef unless _can_accept_sequence($client, $webui_host, $job_sequence, $job_data, \@job_ids_to_grab);
    return undef unless _can_grab_job($client, $worker, $webui_host, $current_job, \@job_ids_to_grab);

    $worker->enqueue_jobs_and_accept_first($client, $job_info);
}

sub _handle_command_incompatible {
    my ($json, $client, $worker, $webui_host, $current_job) = @_;

    # FIXME: It would make more sense to disable only the particular web UI host which is incompatible instead of
    #        just stopping everything.
    log_error("The worker is running a version incompatible with web UI host $webui_host and therefore stopped");
    $worker->stop;
}

1;
