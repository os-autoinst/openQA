# Copyright (C) 2019-2021 SUSE LLC
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

package OpenQA::Worker::Job;
use Mojo::Base 'Mojo::EventEmitter', -signatures;

use OpenQA::Constants qw(DEFAULT_MAX_JOB_TIME DEFAULT_MAX_SETUP_TIME WORKER_COMMAND_ABORT WORKER_COMMAND_QUIT
  WORKER_COMMAND_CANCEL WORKER_COMMAND_OBSOLETE WORKER_SR_SETUP_FAILURE WORKER_SR_API_FAILURE WORKER_SR_TIMEOUT
  WORKER_SR_DONE WORKER_SR_DIED);
use OpenQA::Jobs::Constants;
use OpenQA::Worker::Engines::isotovideo;
use OpenQA::Worker::Isotovideo::Client;
use OpenQA::Log qw(log_error log_warning log_debug log_info);
use OpenQA::Utils qw(find_video_files);

use Digest::MD5;
use Fcntl;
use POSIX 'strftime';
use File::Basename 'basename';
use File::Which 'which';
use MIME::Base64;
use Mojo::JSON 'decode_json';
use Mojo::File 'path';
use Try::Tiny;
use Scalar::Util 'looks_like_number';
use File::Map 'map_file';

# define attributes for public properties
has 'worker';
has 'client';
has 'isotovideo_client' => sub { OpenQA::Worker::Isotovideo::Client->new(job => shift) };
has 'developer_session_running';
has 'upload_results_interval';

use constant AUTOINST_STATUSFILE => 'autoinst-status.json';
use constant BASE_STATEFILE      => 'base_state.json';
use constant UPLOAD_DELAY        => $ENV{OPENQA_UPLOAD_DELAY} // 5;

# define accessors for public read-only properties
sub status                    { shift->{_status} }
sub setup_error               { shift->{_setup_error} }
sub setup_error_category      { shift->{_setup_error_category} }
sub id                        { shift->{_id} }
sub name                      { shift->{_name} }
sub settings                  { shift->{_settings} }
sub info                      { shift->{_info} }
sub developer_session_running { shift->{_developer_session_running} }
sub livelog_viewers           { shift->{_livelog_viewers} }
sub autoinst_log_offset       { shift->{_autoinst_log_offset} }
sub serial_log_offset         { shift->{_serial_log_offset} }
sub serial_terminal_offset    { shift->{_serial_terminal_offset} }
sub images_to_send            { shift->{_images_to_send} }
sub files_to_send             { shift->{_files_to_send} }
sub known_images              { shift->{_known_images} }
sub known_files               { shift->{_known_files} }
sub last_screenshot           { shift->{_last_screenshot} }
sub test_order                { shift->{_test_order} }
sub current_test_module       { shift->{_current_test_module} }
sub progress_info             { shift->{_progress_info} }
sub engine                    { shift->{_engine} }

sub new {
    my ($class, $worker, $client, $job_info) = @_;

    my $self = $class->SUPER::new(
        worker                    => $worker,
        client                    => $client,
        upload_results_interval   => undef,
        developer_session_running => 0,
    );
    $self->{_status}                       = 'new';
    $self->{_id}                           = $job_info->{id};
    $self->{_info}                         = $job_info;
    $self->{_livelog_viewers}              = 0;
    $self->{_autoinst_log_offset}          = 0;
    $self->{_serial_log_offset}            = 0;
    $self->{_serial_terminal_offset}       = 0;
    $self->{_images_to_send}               = {};
    $self->{_files_to_send}                = {};
    $self->{_known_images}                 = [];
    $self->{_known_files}                  = [];
    $self->{_md5sums}                      = {};
    $self->{_last_screenshot}              = '';
    $self->{_current_test_module}          = undef;
    $self->{_progress_info}                = {};
    $self->{_engine}                       = undef;
    $self->{_is_uploading_results}         = 0;
    $self->{_has_uploaded_logs_and_assets} = 0;
    return $self;
}

sub DESTROY {
    my ($self) = @_;
    return if ${^GLOBAL_PHASE} eq 'DESTRUCT';

    $self->_remove_timer;
}

sub _remove_timer {
    my ($self, $timer_names) = @_;
    $timer_names //= [qw(_upload_results_timer _timeout_timer)];

    for my $timer_name (@$timer_names) {
        if (my $timer_id = delete $self->{$timer_name}) {
            Mojo::IOLoop->remove($timer_id);
        }
    }
}

sub _invoke_after_result_upload {
    my ($self, $callback) = @_;

    $self->{_is_uploading_results} ? $self->once(uploading_results_concluded => $callback) : $callback->();
}

sub _result_file_path {
    my ($self, $name) = @_;

    return $self->worker->pool_directory . "/testresults/$name";
}

sub _set_status {
    my ($self, $status, $event_data) = @_;

    $event_data->{job}    = $self;
    $event_data->{status} = $status;
    $self->{_status}      = $status;
    $self->emit(status_changed => $event_data);
}

sub is_stopped_or_stopping {
    my ($self) = @_;

    my $status = $self->status;
    return $status eq 'stopped' || $status eq 'stopping';
}

sub is_uploading_results {
    my ($self) = @_;

    return $self->{_is_uploading_results};
}

sub accept {
    my ($self) = @_;

    my $id   = $self->id;
    my $info = $self->info;
    die 'attempt to accept job without ID and job info' unless $id && defined $info && ref $info eq 'HASH';
    die 'attempt to accept job which is not newly initialized' if $self->status ne 'new';
    $self->_set_status(accepting => {});

    # clear last API error (which happened before this job) and is therefore unrelated
    # note: The last_error attribute is only used within job context.
    my $client = $self->client;
    $client->reset_last_error;

    my $websocket_connection = $client->websocket_connection;
    if (!$websocket_connection) {
        my $webui_host = $client->webui_host;
        return $self->_set_status(
            stopped => {
                error_message =>
                  "Unable to accept job $id because the websocket connection to $webui_host has been lost.",
                reason => WORKER_SR_API_FAILURE,
            });
    }

    $websocket_connection->on(
        finish => sub {
            # note: If the websocket connection goes down this is not critical to the job execution.
            #       However, if it goes down before we can send the "accepted" message we should scrap the
            #       job and just wait for the next "grab job" message. Otherwise the job would end up in
            #       perpetual 'accepting' state.
            $self->stop(WORKER_SR_API_FAILURE) if ($self->status eq 'accepting' || $self->status eq 'new');
        });
    $websocket_connection->send(
        {json => {type => 'accepted', jobid => $self->id}},
        sub {
            $self->_set_status(accepted => {});
        });
    return 1;
}

sub _compute_timeouts ($job_settings) {
    my $max_job_time   = $job_settings->{MAX_JOB_TIME};
    my $max_setup_time = $job_settings->{MAX_SETUP_TIME};
    my $timeout_scale  = $job_settings->{TIMEOUT_SCALE};
    $max_job_time   = DEFAULT_MAX_JOB_TIME   unless looks_like_number $max_job_time;
    $max_setup_time = DEFAULT_MAX_SETUP_TIME unless looks_like_number $max_setup_time;
    # disable video for long-running scenarios by default
    $job_settings->{NOVIDEO} = 1    if !exists $job_settings->{NOVIDEO} && $max_job_time > DEFAULT_MAX_JOB_TIME;
    $max_job_time *= $timeout_scale if looks_like_number $timeout_scale;
    return ($max_job_time, $max_setup_time);
}

sub _handle_timeout ($self, $engine = undef) {
    # prevent to determine status of job from exit_status
    eval {
        if (my $child = $engine->{child}) {
            $child->session->_protect(sub { $child->unsubscribe('collected') });
        }
    } if $engine;
    # abort job
    $self->_remove_timer;
    $self->stop(WORKER_SR_TIMEOUT);
}

sub _set_timeout ($self, $timeout, $engine = undef) {
    my $loop = Mojo::IOLoop->singleton;
    if (my $current_timer = $self->{_timeout_timer}) { $loop->remove($current_timer) }
    $self->{_timeout_timer} = $loop->timer($timeout => sub { $self->_handle_timeout($engine) });
}

sub start {
    my ($self) = @_;

    my $id   = $self->id;
    my $info = $self->info;
    die 'attempt to start job without ID and job info' unless $id && defined $info && ref $info eq 'HASH';
    die 'attempt to start job which is not accepted'   unless $self->status eq 'accepted';
    $self->_set_status(setup => {});

    # delete settings we better not allow to be set on job-level (and instead should only be set within the
    # worker config)
    my $job_settings = $self->info->{settings} // {};
    delete $job_settings->{GENERAL_HW_CMD_DIR};
    for my $key (keys %$job_settings) {
        delete $job_settings->{$key} if rindex($key, 'EXTERNAL_VIDEO_ENCODER', 0) == 0;
    }

    # update settings received from web UI with worker-specific stuff
    my $worker                 = $self->worker;
    my $global_worker_settings = $worker->settings->global_settings;
    @{$job_settings}{keys %$global_worker_settings} = values %$global_worker_settings;
    $self->{_settings} = $job_settings;
    $self->{_name}     = $job_settings->{NAME};

    # ensure log files are empty/removed
    if (my $pooldir = $worker->pool_directory) {
        open(my $fd, '>', "$pooldir/worker-log.txt") or log_error("Could not open worker log: $!");
        foreach my $file (qw(serial0.txt autoinst-log.txt serial_terminal.txt)) {
            next unless -e "$pooldir/$file";
            unlink("$pooldir/$file") or log_error("Could not unlink '$file': $!");
        }
    }

    # set OPENQA_HOSTNAME environment variable (likely not used anywhere but who knows for sure)
    my $client     = $self->client;
    my $webui_host = $client->webui_host;
    ($ENV{OPENQA_HOSTNAME}) = $webui_host =~ m|([^/]+:?\d*)/?$|;

    # set base dir to the one assigned with web UI
    $ENV{OPENQA_SHAREDIR} = $client->working_directory;

    # stop setup if timeout has been exceeded
    my ($max_job_time, $max_setup_time) = _compute_timeouts($job_settings);
    $self->_set_timeout($max_setup_time);

    # start isotovideo
    # FIXME: isotovideo.pm could be a class inheriting from Job.pm or simply be merged
    return OpenQA::Worker::Engines::isotovideo::engine_workit($self,
        sub ($engine) { $self->_handle_engine_startup($engine, $max_job_time) });
}

sub _handle_engine_startup ($self, $engine, $max_job_time) {
    my $setup_error = $engine->{error};
    $setup_error = 'isotovideo can not be started'
      if !$setup_error && ($engine->{child}->errored || !$engine->{child}->is_running);
    if ($self->{_setup_error} = $setup_error) {
        # let the IO loop take over if the job has been stopped during setup
        # notes: - Stop has already been called at this point and async code for stopping is setup to run
        #          on the event loop.
        #        - This can happen if stop is called from an interrupt or the job has been cancelled by the
        #          web UI.
        return undef if $self->is_stopped_or_stopping;

        my $id = $self->id;
        log_error("Unable to setup job $id: $setup_error");
        $self->{_setup_error_category} = $engine->{category} // WORKER_SR_SETUP_FAILURE;
        return $self->stop(WORKER_SR_SETUP_FAILURE);
    }

    my $isotovideo_pid = $engine->{child}->pid() // 'unknown';
    log_info("isotovideo has been started (PID: $isotovideo_pid)");
    $self->{_engine} = $engine;

    # schedule initial status update and result upload which will also trigger subsequent updates
    Mojo::IOLoop->next_tick(
        sub {
            $self->client->send_status();
            $self->_upload_results(sub { });
        });

    # stop execution if timeout has been exceeded
    $self->_set_timeout($max_job_time, $engine);

    $self->_set_status(running => {});
}

sub kill {
    my ($self) = @_;

    my $engine = $self->engine;
    return unless $engine;

    my $child = $engine->{child};
    $child->stop if $child && $child->is_running;
}

sub skip {
    my ($self, $reason) = @_;

    my $status = $self->status;
    die "attempt to skip $status job; only new jobs can be skipped" unless $status eq 'new';

    $reason //= 'skipped';
    $self->_set_status(stopping => {reason => $reason});
    $self->_stop_step_5_finalize($reason, {result => OpenQA::Jobs::Constants::SKIPPED});
    return 1;
}

sub stop ($self, $reason = undef) {
    $reason //= '';

    # ignore calls to stop if already stopped or stopping
    # note: This method might be called at any time (including when an interrupted happens).
    return undef if $self->is_stopped_or_stopping;

    my $status = $self->status;
    $self->_set_status(stopped => {reason => $reason}) and return undef
      unless $status eq 'setup' || $status eq 'running';

    $self->_set_status(stopping => {reason => $reason});
    $self->_remove_timer(['_timeout_timer']);

    $self->_stop_step_2_post_status(
        $reason,
        sub {
            $self->_stop_step_3_announce(
                $reason,
                sub {
                    $self->kill;
                    $self->_stop_step_4_upload(
                        $reason,
                        sub {
                            my ($params_for_finalize, $duplication_res) = @_;
                            my $duplication_failed = defined $duplication_res && !$duplication_res;
                            $self->_stop_step_5_finalize($duplication_failed ? WORKER_SR_API_FAILURE : $reason,
                                $params_for_finalize);
                        });
                });
        });
}

sub _stop_step_2_post_status ($self, $reason, $callback) {
    my $job_id = $self->id;
    my $client = $self->client;
    $client->send(
        post => "jobs/$job_id/status",
        json => {
            status => {uploading => 1, worker_id => $client->worker_id},
        },
        callback => $callback,
    );
}

sub _stop_step_3_announce ($self, $reason, $callback) {

    # skip if isotovideo not running anymore (e.g. when isotovideo just exited on its own)
    return Mojo::IOLoop->next_tick($callback) unless $self->is_backend_running;

    $self->isotovideo_client->stop_gracefully($reason, $callback);
}

sub _stop_step_4_upload ($self, $reason, $callback) {
    my $job_id  = $self->id;
    my $pooldir = $self->worker->pool_directory;

    # add notes
    log_info("+++ worker notes +++",                             channels => 'autoinst');
    log_info(sprintf("End time: %s", strftime("%F %T", gmtime)), channels => 'autoinst');
    log_info("Result: $reason",                                  channels => 'autoinst');

    # upload logs and assets
    return Mojo::IOLoop->next_tick(sub { $self->_stop_step_5_1_upload($reason, $callback) })
      if $reason eq WORKER_COMMAND_QUIT || $reason eq 'abort' || $reason eq WORKER_SR_API_FAILURE;
    Mojo::IOLoop->subprocess(
        sub {
            # upload ulogs
            my @uploaded_logfiles = glob "$pooldir/ulogs/*";
            for my $file (@uploaded_logfiles) {
                next unless -f $file;

                my %upload_parameter = (
                    file => {file => $file, filename => basename($file)},
                    ulog => 1,
                );
                if (!$self->_upload_log_file_or_asset(\%upload_parameter)) {
                    $reason = WORKER_SR_API_FAILURE;
                    last;
                }
            }

            # upload assets created by successful jobs
            if ($reason eq WORKER_SR_DONE || $reason eq WORKER_COMMAND_CANCEL) {
                for my $dir (qw(private public)) {
                    my @assets        = glob "$pooldir/assets_$dir/*";
                    my $upload_result = 1;

                    for my $file (@assets) {
                        next unless -f $file;

                        my %upload_parameter = (
                            file  => {file => $file, filename => basename($file)},
                            asset => $dir,
                        );
                        last unless ($upload_result = $self->_upload_log_file_or_asset(\%upload_parameter));
                    }
                    if (!$upload_result) {
                        $reason = WORKER_SR_API_FAILURE;
                        last;
                    }
                }
            }

            my @other = (
                @{find_video_files($pooldir)->map('basename')->to_array},
                COMMON_RESULT_FILES,
                qw(serial0 video_time.vtt serial_terminal.txt virtio_console.log virtio_console1.log)
            );
            for my $other (@other) {
                my $file = "$pooldir/$other";
                next unless -e $file;

                # replace some file names
                my $ofile = $file;
                $ofile =~ s/serial0/serial0.txt/;
                $ofile =~ s/virtio_console.log/serial_terminal.txt/;

                my %upload_parameter = (file => {file => $file, filename => basename($ofile)});
                if (!$self->_upload_log_file_or_asset(\%upload_parameter)) {
                    $reason = WORKER_SR_API_FAILURE;
                    last;
                }
            }
            return $reason;
        },
        sub {
            my ($subprocess, $err, $reason) = @_;
            log_error("Upload subprocess error: $err") if $err;
            $self->_stop_step_5_1_upload($reason // WORKER_SR_API_FAILURE, $callback);
        });
}

sub _stop_step_5_1_upload ($self, $reason, $callback) {

    # signal a possibly ongoing result upload that logs and assets have been uploaded
    $self->{_has_uploaded_logs_and_assets} = 1;
    $self->emit(uploading_logs_and_assets_concluded => {});
    # ensure no asynchronous "side tasks" are started anymore automatically at this point
    $self->_remove_timer;
    # postpone any further actions until a possibly ongoing result upload has been concluded
    $self->_invoke_after_result_upload(sub { $self->_stop_step_5_2_upload($reason, $callback); });
}

sub _stop_step_5_2_upload ($self, $reason, $callback) {

    # do final status upload for selected reasons
    my $job_id = $self->id;
    if ($reason eq WORKER_COMMAND_OBSOLETE) {
        log_debug("Considering job $job_id as incomplete due to obsoletion");
        return $self->_upload_results(sub { $callback->({result => INCOMPLETE, newbuild => 1}) });
    }
    if ($reason eq WORKER_COMMAND_CANCEL) {
        log_debug("Considering job $job_id as cancelled/restarted by the user");
        return $self->_upload_results(sub { $callback->({result => USER_CANCELLED}) });
    }
    if ($reason eq WORKER_SR_DONE) {
        log_debug("Considering job $job_id as regularly done");
        return $self->_upload_results(sub { $callback->(); });
    }

    if ($reason eq WORKER_SR_API_FAILURE) {
        # give the API one last try to incomplete the job at least
        # note: Setting 'ignore_errors' here is important. Otherwise we would endlessly repeat
        #       that API call.
        return $self->_set_job_done(
            $reason,
            {result => OpenQA::Jobs::Constants::INCOMPLETE},
            sub {
                # try to replenish registration (maybe the error is caused by wrong registration)
                $self->client->register;
                $callback->();
            });
    }

    my $result;
    if ($reason eq WORKER_SR_TIMEOUT) {
        log_warning("Job $job_id stopped because it exceeded MAX_JOB_TIME");
        $result = TIMEOUT_EXCEEDED;
    }
    else {
        log_debug("Job $job_id stopped as incomplete");
        $result = INCOMPLETE;
    }

    # do final status upload and set result unless abort reason is "quit"
    return $self->_upload_results(sub { $callback->({result => $result}) }) if $reason ne WORKER_COMMAND_QUIT;

    # duplicate job if abort reason is "quit"; do final status upload and incomplete job
    log_debug("Duplicating job $job_id");
    my $client = $self->client;
    $client->send(
        post     => "jobs/$job_id/duplicate",
        params   => {dup_type_auto => 1},
        callback => sub {
            my ($duplication_res) = @_;
            if (!$duplication_res) {
                log_warning("Failed to duplicate job $job_id.");
                $client->add_context_to_last_error("duplication after $reason");
            }
            $self->_upload_results(sub { $callback->({result => INCOMPLETE}, $duplication_res) });
        });
}

sub _format_reason {
    my ($self, $result, $reason) = @_;

    # format stop reasons from the worker itself
    return 'timeout: ' . ($self->{_engine} ? 'test execution exceeded MAX_JOB_TIME' : 'setup exceeded MAX_SETUP_TIME')
      if $reason eq WORKER_SR_TIMEOUT;
    return "$self->{_setup_error_category}: $self->{_setup_error}" if $reason eq WORKER_SR_SETUP_FAILURE;
    if ($reason eq WORKER_SR_API_FAILURE) {
        my $last_client_error = $self->client->last_error;
        return $last_client_error ? "api failure: $last_client_error" : 'api failure';
    }
    return 'quit: worker has been stopped or restarted' if $reason eq WORKER_COMMAND_QUIT;
    # the result is sufficient here
    return undef if $reason eq WORKER_COMMAND_CANCEL;

    # consider other reasons as os-autoinst specific; retrieve extended reason if available
    my $state_file = path($self->worker->pool_directory)->child(BASE_STATEFILE);
    try {
        if (-e $state_file) {
            my $state = decode_json($state_file->slurp);
            die 'top-level element is not a hash' unless ref $state eq 'HASH';
            if (my $component = $state->{component}) {
                # prepent the relevant component, e.g. turn "died" into "backend died" or "tests died"
                $reason = "$component $reason" unless $component =~ qr/$[\w\d]^/;
            }
            if (my $msg = $state->{msg}) {
                # append additional information, e.g. turn "backend died" into "backend died: qemu crashed"
                my $first_line = ($msg =~ /\A(.*?)$/ms)[0];
                $reason = "$reason: $first_line";
            }
        }
    }
    catch {
        # read autoinst-log.txt to check the reason, see poo#80334
        my $msg = '';
        eval {
            map_file my $log_content, path($self->worker->pool_directory, 'autoinst-log.txt'), '<';
            $msg = ': No space left on device' if ($log_content =~ /No space left on device/);
        };
        log_warning($@) if $@;

        if ($reason eq WORKER_SR_DONE) {
            $reason = "$reason: terminated with corrupted state file$msg";
        }
        else {
            $reason = "terminated prematurely: Encountered corrupted state file$msg, see log output for details";
        }
        log_warning("Found $state_file but failed to parse the JSON: $_");
    };

    # return generic phrase if the reason would otherwise just be died
    return "$reason: terminated prematurely, see log output for details" if $reason eq WORKER_SR_DIED;

    # return API failure if final result upload ended with an error and there's no more relevant reason
    my $result_upload_error = $self->{_result_upload_error};
    return "api failure: $result_upload_error" if $result_upload_error && $reason eq WORKER_SR_DONE;

    # discard the reason if it is just WORKER_SR_DONE or the same as the result; otherwise return it
    return undef unless $reason ne WORKER_SR_DONE && (!defined $result || $result ne $reason);
    return $reason;
}

sub _set_job_done ($self, $reason, $params, $callback) {

    # pass the reason if it is an additional specification of the result
    my $formatted_reason = $self->_format_reason($params->{result}, $reason);
    $params->{reason} = $formatted_reason if defined $formatted_reason;

    my $job_id = $self->id;
    my $client = $self->client;
    $params->{worker_id} = $client->worker_id;
    return $client->send(
        post          => "jobs/$job_id/set_done",
        params        => $params,
        non_critical  => 1,
        ignore_errors => 1,
        callback      => $callback,
    );
}

sub _stop_step_5_finalize ($self, $reason, $params) {
    $self->_set_job_done($reason, $params, sub { $self->_set_status(stopped => {reason => $reason}) });

    # note: The worker itself will react the the changed status and unassign this job object
    #       from its current_job property and will clean the pool directory.
}

sub is_backend_running {
    my ($self) = @_;

    my $engine = $self->engine;
    return !!0 unless $engine;
    return !exists $engine->{child} ? !!0 : $engine->{child}->is_running;
}

sub start_livelog {
    my ($self) = @_;

    return undef unless $self->is_backend_running;

    my $pooldir         = $self->worker->pool_directory;
    my $livelog_viewers = $self->livelog_viewers + 1;
    if ($livelog_viewers == 1) {
        log_debug('Starting livelog');
        open(my $fh, '>', "$pooldir/live_log") or die "Cannot create live_log file";
        close($fh);
    }
    $self->{_livelog_viewers} = $livelog_viewers;
    $self->upload_results_interval(undef);
    $self->_upload_results(sub { });
}

sub stop_livelog {
    my ($self) = @_;

    return unless $self->is_backend_running;

    my $pooldir         = $self->worker->pool_directory;
    my $livelog_viewers = $self->livelog_viewers;
    $livelog_viewers -= 1 if $livelog_viewers >= 1;
    if ($livelog_viewers == 0) {
        log_debug('Stopping livelog');
        unlink "$pooldir/live_log";
    }
    $self->{_livelog_viewers} = $livelog_viewers;
    $self->upload_results_interval(undef);
}

# posts the setup status
# note: Called by the engine while preparing the startup so the job is not considered dead by the
#       web UI if this takes longer.
sub post_setup_status {
    my ($self) = @_;

    # allow the worker to stop when interrupted during setup
    return 0 if ($self->is_stopped_or_stopping);

    my $client    = $self->client;
    my $job_id    = $self->id;
    my $worker_id = $client->worker_id;
    die 'attempt to post setup status without worker and/or job ID' unless defined $worker_id && defined $job_id;
    log_debug("Updating status so job $job_id is not considered dead.");
    $client->send(
        post     => "jobs/$job_id/status",
        json     => {status => {setup => 1, worker_id => $worker_id}},
        callback => 'no',
    );
    return 1;
}

sub _calculate_upload_results_interval {
    my ($self) = @_;

    my $interval = $self->upload_results_interval;
    return $interval if $interval;
    $interval = $self->livelog_viewers >= 1 ? 1 : 10;
    $self->upload_results_interval($interval);
    return $interval;
}

sub _conclude_upload ($self, $callback, $result = {}) {
    $self->{_is_uploading_results} = 0;
    $self->emit(uploading_results_concluded => $result);
    return Mojo::IOLoop->next_tick($callback);
}

sub _upload_results {
    my ($self, $callback) = @_;

    # ensure an ongoing timer is cancelled in case upload_results has been called manually
    if (my $upload_results_timer = delete $self->{_upload_results_timer}) {
        Mojo::IOLoop->remove($upload_results_timer);
    }

    # return if job setup is insufficient
    if (!$self->isotovideo_client->url || !$self->client->worker_id) {
        log_warning('Unable to upload results of the job because no command server URL or worker ID have been set.');
        return $self->_conclude_upload($callback);
    }

    $self->{_is_uploading_results} = 1;
    $self->{_result_upload_error}  = undef;
    $self->_upload_results_step_0_prepare($callback);
}

sub _upload_results_step_0_prepare {
    my ($self, $callback) = @_;

    my $worker_id       = $self->client->worker_id;
    my $job_url         = $self->isotovideo_client->url;
    my $global_settings = $self->worker->settings->global_settings;
    my $pooldir         = $self->worker->pool_directory;
    my $status_file     = "$pooldir/" . AUTOINST_STATUSFILE;
    my %status          = (
        worker_id             => $worker_id,
        cmd_srv_url           => $job_url,
        worker_hostname       => $global_settings->{WORKER_HOSTNAME},
        test_execution_paused => 0,
    );

    my $test_status  = -r $status_file ? decode_json(path($status_file)->slurp) : {};
    my $test_state   = $test_status->{status}       || '';
    my $running_test = $test_status->{current_test} || '';
    my $finished     = $test_state eq 'finished'    || $self->{_has_uploaded_logs_and_assets};
    $status{test_execution_paused} = $test_status->{test_execution_paused} // 0;

    # determine up to which module the results should be uploaded
    my $current_test_module = $self->current_test_module;
    my $upload_up_to;
    if ($test_state eq 'running' || $finished) {
        my @file_info = stat $self->_result_file_path('test_order.json');
        my $test_order;
        my $changed_schedule = (
            $self->{_test_order_mtime} and ($file_info[9] != $self->{_test_order_mtime}
                or $file_info[7] != $self->{_test_order_fsize}));
        if (not $current_test_module or $changed_schedule) {
            log_info('Test schedule has changed, reloading test_order.json') if $changed_schedule;
            $test_order                = $self->_read_json_file('test_order.json');
            $status{test_order}        = $test_order;
            $self->{_test_order}       = $test_order;
            $self->{_full_test_order}  = $test_order;
            $self->{_test_order_mtime} = $file_info[9];
            $self->{_test_order_fsize} = $file_info[7];
        }
        if (!$current_test_module) {    # first test (or already after the last!)
            if (!$test_order) {
                $self->stop('no tests scheduled');
                return $self->_conclude_upload($callback, {upload_up_to => $upload_up_to});
            }
        }
        elsif ($current_test_module ne $running_test) {    # next test
            $upload_up_to = $current_test_module;
        }
        if ($running_test or $finished) {
            # $running_test could be empty in between tests
            # prevent $current_test_module from getting empty
            $self->{_current_test_module} = $current_test_module = $running_test;
        }
    }

    # adjust $upload_up_to to handle special cases
    if ($self->{_has_uploaded_logs_and_assets}) {
        # ensure everything is uploaded in the end
        $upload_up_to = '';
        $status{test_order} = $self->{_test_order} = $self->{_full_test_order};
    }
    elsif ($status{test_execution_paused}) {
        # upload up to the current module when paused so it is possible to open the needle editor
        $upload_up_to = $current_test_module;
    }

    # upload all results up to $upload_up_to
    my $last_test_module;
    ($status{result}, $last_test_module) = $self->_read_result_file($upload_up_to, $status{test_order} //= [])
      if defined $upload_up_to;

    # provide last screen and live log
    if ($self->livelog_viewers >= 1) {
        my $pool_directory = $self->worker->pool_directory;
        $status{log}             = $self->_log_snippet("$pool_directory/autoinst-log.txt",   'autoinst_log_offset');
        $status{serial_log}      = $self->_log_snippet("$pool_directory/serial0",            'serial_log_offset');
        $status{serial_terminal} = $self->_log_snippet("$pool_directory/virtio_console.log", 'serial_terminal_offset');
        if (my $screen = $self->_read_last_screen) {
            $status{screen} = $screen;
        }
    }

    # mark the currently running test as running
    $status{result}->{$current_test_module}->{result} = 'running'
      if $current_test_module && !$self->is_stopped_or_stopping;

    # define steps for uploading status to web UI
    return $self->_upload_results_step_1_post_status(
        \%status,
        sub {
            my ($status_post_res) = @_;

            # handle error occurred when posting the status
            if (!$status_post_res) {
                if ($self->is_stopped_or_stopping) {
                    log_error('Unable to make final image uploads. Maybe the web UI considers this job already dead.');
                }
                else {
                    log_error('Aborting job because web UI doesn\'t accept new images anymore'
                          . ' (likely considers this job dead)');
                    $self->stop(WORKER_SR_API_FAILURE);
                }
                $self->{_result_upload_error} = 'Unable to upload images: posting status failed';
                return $self->_upload_results_step_3_finalize($upload_up_to, $callback);
            }

            $self->_reduce_test_order($last_test_module)
              if defined $upload_up_to && defined $last_test_module && !$self->{_has_uploaded_logs_and_assets};
            $self->_ignore_known_images($status_post_res->{known_images});
            $self->_ignore_known_files($status_post_res->{known_files});

            # upload images; inform liveviewhandler before and after about the progress if developer session opened
            return $self->post_upload_progress_to_liveviewhandler(
                $upload_up_to,
                sub {
                    $self->_upload_results_step_2_upload_images(
                        sub {
                            return $self->post_upload_progress_to_liveviewhandler(
                                $upload_up_to,
                                sub {
                                    $self->_upload_results_step_3_finalize($upload_up_to, $callback);
                                });
                        });

                });
        });
}

sub _upload_results_step_1_post_status {
    my ($self, $status, $callback) = @_;

    my $job_id = $self->id;
    $self->client->send(
        post         => "jobs/$job_id/status",
        json         => {status => $status},
        non_critical => $self->is_stopped_or_stopping,
        callback     => $callback,
    );
}

sub _upload_results_step_2_1_upload_images ($self) {
    my ($job_id, $client) = ($self->id, $self->client);
    my $images_to_send = $self->images_to_send;
    for my $md5 (keys %$images_to_send) {
        my $file = $images_to_send->{$md5};
        _optimize_image($self->_result_file_path($file));

        my %args
          = (file => {file => $self->_result_file_path($file), filename => $file}, image => 1, thumb => 0, md5 => $md5);
        $self->_upload_log_file(\%args);

        my $thumb = $self->_result_file_path(".thumbs/$file");
        next unless -f $thumb;
        _optimize_image($thumb);
        my %thumb_args = (file => {file => $thumb, filename => $file}, image => 1, thumb => 1, md5 => $md5);
        $self->_upload_log_file(\%thumb_args);
    }

    for my $file (keys %{$self->files_to_send}) {
        my %args = (file => {file => $self->_result_file_path($file), filename => $file}, image => 0, thumb => 0);
        $self->_upload_log_file(\%args);
    }
}

sub _upload_results_step_2_2_upload_images ($self, $callback, $error) {
    chomp $error;
    log_error($self->{_result_upload_error} = "Unable to upload images: $error") if $error;
    $self->{_images_to_send} = {};
    $self->{_files_to_send}  = {};
    $callback->();
}

sub _upload_results_step_2_upload_images ($self, $callback) {
    Mojo::IOLoop->subprocess(sub { $self->_upload_results_step_2_1_upload_images },
        sub ($subprocess, $error, @args) { $self->_upload_results_step_2_2_upload_images($callback, $error) });
}

sub _upload_results_step_3_finalize ($self, $upload_up_to, $callback) {

    # continue uploading results to update the live log until logs and assets have been uploaded
    unless ($self->{_has_uploaded_logs_and_assets}) {
        my $interval = $self->_calculate_upload_results_interval;
        $self->{_upload_results_timer} = Mojo::IOLoop->timer(
            $interval,
            sub {
                $self->_upload_results(sub { });
            });
    }

    $self->_conclude_upload($callback, {upload_up_to => $upload_up_to});
}

sub post_upload_progress_to_liveviewhandler {
    my ($self, $upload_up_to, $callback) = @_;

    return Mojo::IOLoop->next_tick($callback) if $self->is_stopped_or_stopping || !$self->developer_session_running;

    my $current_test_module = $self->current_test_module;
    my %new_progress_info   = (
        upload_up_to                => $upload_up_to,
        upload_up_to_current_module => $current_test_module && $upload_up_to && $current_test_module eq $upload_up_to,
        outstanding_files           => scalar(keys %{$self->files_to_send}),
        outstanding_images          => scalar(keys %{$self->images_to_send}),
    );

    # skip if the progress hasn't changed
    my $progress_changed;
    my $current_progress_info = $self->progress_info;
    for my $key (qw(upload_up_to upload_up_to_current_module outstanding_files outstanding_images)) {
        my $new_value = $new_progress_info{$key};
        my $old_value = $current_progress_info->{$key};
        if (defined($new_value) != defined($old_value) || (defined($new_value) && $new_value ne $old_value)) {
            $progress_changed = 1;
            last;
        }
    }
    return Mojo::IOLoop->next_tick($callback) unless $progress_changed;
    $self->{_progress_info} = \%new_progress_info;

    my $job_id = $self->id;
    $self->client->send(
        post               => "/liveviewhandler/api/v1/jobs/$job_id/upload_progress",
        service_port_delta => 2,                     # liveviewhandler is supposed to run on web UI port + 2
        json               => \%new_progress_info,
        non_critical       => 1,
        callback           => sub {
            my ($res) = @_;
            log_warning('Failed to post upload progress to liveviewhandler.') unless $res;
            $callback->($res);
        });
}

sub _upload_log_file_or_asset {
    my ($self, $upload_parameter) = @_;

    my $filename = $upload_parameter->{file}->{filename};
    my $file     = $upload_parameter->{file}->{file};
    my $is_asset = $upload_parameter->{asset};
    log_info("Uploading $filename", channels => ['worker', 'autoinst'], default => 1);
    return $is_asset ? $self->_upload_asset($upload_parameter) : $self->_upload_log_file($upload_parameter);
}

sub _log_upload_error ($self, $filename, $tx) {
    return undef unless my $err = $tx->error;

    my $error_type    = $err->{code} ? "$err->{code} response" : 'connection error';
    my $error_message = "Error uploading $filename: $error_type: $err->{message}";
    die "$error_message\n" if $self->{_has_uploaded_logs_and_assets};
    log_error $error_message, channels => ['autoinst', 'worker'], default => 1;
    return 1;
}

sub _upload_asset {
    my ($self, $upload_parameter) = @_;

    my $job_id               = $self->id;
    my $filename             = $upload_parameter->{file}->{filename};
    my $file                 = $upload_parameter->{file}->{file};
    my $chunk_size           = $self->worker->settings->global_settings->{UPLOAD_CHUNK_SIZE} // 1000000;
    my $local_upload         = $self->worker->settings->global_settings->{LOCAL_UPLOAD}      // 1;
    my $ua                   = $self->client->ua;
    my @channels_worker_only = ('worker');
    my @channels_both        = ('autoinst', 'worker');
    my $error;

    log_info("Uploading $filename using multiple chunks", channels => \@channels_worker_only, default => 1);

    $ua->upload->once(
        'upload_local.prepare' => sub ($upload) {
            log_info("$filename: local upload (no chunks needed)", channels => \@channels_worker_only, default => 1);
            chmod 0644, $file;
        });
    $ua->upload->once(
        'upload_chunk.prepare' => sub ($upload, $pieces) {
            log_info("$filename: " . $pieces->size() . " chunks",   channels => \@channels_worker_only, default => 1);
            log_info("$filename: chunks of $chunk_size bytes each", channels => \@channels_worker_only, default => 1);
        });
    my $t_start;
    $ua->upload->on('upload_chunk.start' => sub { $t_start = time() });
    $ua->upload->on(
        'upload_chunk.finish' => sub ($upload, $piece) {
            my $index                = $piece->index;
            my $total                = $piece->total;
            my $spent                = (time() - $t_start) || 1;
            my $kbytes               = ($piece->end - $piece->start) / 1024;
            my $speed                = sprintf('%.3f', $kbytes / $spent);
            my $show_in_autoinst_log = $index % 10 == 0 || $piece->is_last;
            log_info(
                "$filename: Processing chunk $index/$total, avg. speed ~${speed} KiB/s",
                channels => ($show_in_autoinst_log ? \@channels_both : \@channels_worker_only),
                default  => 1
            );
        });

    my $response_cb = sub ($upload, $tx) {
        if ($tx->res->is_server_error) {
            log_error($tx->res->json->{error}, channels => \@channels_both, default => 1)
              if $tx->res->json && $tx->res->json->{error};
            my $msg = "Failed uploading asset";
            log_error($msg, channels => \@channels_both, default => 1);
        }
        $self->_log_upload_error($filename, $tx);
    };
    $ua->upload->on('upload_local.response' => $response_cb);
    $ua->upload->on('upload_chunk.response' => $response_cb);
    $ua->upload->on(
        'upload_chunk.fail' => sub ($upload, $res, $chunk) {
            log_error('Upload failed for chunk ' . $chunk->index, channels => \@channels_both, default => 1);
            sleep UPLOAD_DELAY;    # do not choke webui
        });

    $ua->upload->once(
        'upload_chunk.error' => sub {
            $error = pop();
            log_error(
                'Upload failed, and all retry attempts have been exhausted',
                channels => \@channels_both,
                default  => 1
            );
        });

    local $@;
    eval {
        $ua->upload->asset(
            $job_id => {
                file       => $file,
                name       => $filename,
                asset      => $upload_parameter->{asset},
                chunk_size => $chunk_size,
                local      => $local_upload
            });
    };
    log_error($@, channels => \@channels_both, default => 1) if $@;

    $ua->upload->unsubscribe($_)
      for qw(upload_local.prepare upload_local.response upload_chunk.request_err upload_chunk.error upload_chunk.fail),
      qw( upload_chunk.response upload_chunk.start upload_chunk.finish upload_chunk.prepare);

    return 0 if $@ || $error;
    return 1;
}

sub _upload_log_file ($self, $upload_parameter) {
    my $job_id        = $self->id;
    my $md5           = $upload_parameter->{md5};
    my $filename      = $upload_parameter->{file}->{filename};
    my $client        = $self->client;
    my $retry_limit   = $client->configured_retries;
    my $retry_counter = $retry_limit;
    my ($url, $ua) = ($client->url, $client->ua);
    my ($tx, $res, $error_message, $retry_delay);

    log_debug("Uploading artefact $filename" . ($md5 ? " as $md5" : ''));
    while (1) {
        my $ua_url = $url->clone;
        $ua_url->path("jobs/$job_id/artefact");
        $tx = $ua->build_tx(POST => $ua_url => form => $upload_parameter);

        ($error_message, $retry_delay) = $client->evaluate_error($ua->start($tx), \$retry_counter);
        last unless $error_message;

        if ($retry_counter <= 0) {
            my $msg = "All $retry_limit upload attempts have failed for $filename";
            log_error $msg, channels => ['autoinst', 'worker'], default => 1;
            last;
        }

        log_warning "Upload attempts remaining: $retry_counter/$retry_limit for $filename";
        sleep $retry_delay;
    }

    return 0 if $self->_log_upload_error($filename, $tx);
    return 1;
}

sub _read_json_file {
    my ($self, $name) = @_;

    my $file_name = $self->_result_file_path($name);
    my $json_data = eval { path($file_name)->slurp };
    if (my $error = $@) {
        log_debug("Unable to read $name: $error");
        return undef;
    }
    my $json = eval { decode_json($json_data) } // {};
    log_warning("os-autoinst didn't write valid JSON file $file_name") if $@;
    return $json;
}

# uploads all results not yet uploaded - and stop at $upload_up_to
# if $upload_up_to is empty string, then upload everything
sub _read_result_file ($self, $upload_up_to, $extra_test_order) {
    my $test_order = $self->test_order;
    my (%ret, $last_test_module);
    return (\%ret, $last_test_module) unless $test_order;
    for my $test_module (@$test_order) {
        my $test   = $test_module->{name};
        my $result = $self->_read_module_result($test);
        last unless $result;

        $last_test_module = $test;
        $ret{$test} = $result;
        if ($result->{extra_test_results}) {
            for my $extra_test (@{$result->{extra_test_results}}) {
                my $extra_result = $self->_read_module_result($extra_test->{name});
                next unless $extra_result;
                $ret{$extra_test->{name}} = $extra_result;
            }
            push @{$extra_test_order}, @{$result->{extra_test_results}};
        }

        last if $test eq $upload_up_to;
    }
    return (\%ret, $last_test_module);
}

# removes all modules which have already been finished from the test order to avoid
# re-reading these results on every further upload during the test execution (except final upload)
sub _reduce_test_order ($self, $last_test_module) {
    my ($test_order, $current_test_module) = ($self->test_order, $self->current_test_module);
    return undef unless $test_order && $current_test_module;

    my $modules_considered_processed = 0;
    for my $test_module (@$test_order) {
        my $test_name = $test_module->{name};
        last if $test_name eq $current_test_module;
        ++$modules_considered_processed;
        last if $test_name eq $last_test_module;
    }
    splice @$test_order, 0, $modules_considered_processed;
}

sub _read_module_result {
    my ($self, $test) = @_;

    my $result = $self->_read_json_file("result-$test.json");
    return undef   unless ref($result) eq 'HASH';
    return $result unless $result->{details};

    my $images_to_send = $self->images_to_send;
    my $files_to_send  = $self->files_to_send;
    for my $d (@{$result->{details}}) {
        for my $type (qw(screenshot audio text)) {
            my $file = $d->{$type};
            next unless $file;

            if ($type eq 'screenshot') {
                my $md5 = $self->_calculate_file_md5("testresults/$file");
                $d->{$type} = {
                    name => $file,
                    md5  => $md5,
                };
                $images_to_send->{$md5} = $file;
            }
            else {
                $files_to_send->{$file} = 1;
            }
        }
    }
    return $result;
}

sub _calculate_file_md5 {
    my ($self, $file) = @_;

    # return previously calculated checksum for that file
    # note: We're optimizing the image immediately before the upload (which is after computing the md5sum).
    #       So the web UI knows the md5sum of the unoptimized image. If we re-read the results of a test module
    #       a 2nd time (e.g. on the final upload) we should still use that first md5sum of the unoptimized image
    #       to avoid assuming it is now a different image.
    my $md5sums    = $self->{_md5sums};
    my $cached_sum = $md5sums->{$file};
    return $cached_sum if defined $cached_sum;

    my $c   = path($self->worker->pool_directory, $file)->slurp;
    my $md5 = Digest::MD5->new;
    $md5->add($c);
    return $md5sums->{$file} = $md5->clone->hexdigest;
}

sub _read_last_screen {
    my ($self) = @_;

    my $pooldir  = $self->worker->pool_directory;
    my $lastlink = readlink("$pooldir/qemuscreenshot/last.png");
    return if !$lastlink || $self->last_screenshot eq $lastlink;
    my $png = encode_base64(path($pooldir, "qemuscreenshot/$lastlink")->slurp);
    $self->{_last_screenshot} = $lastlink;
    return {name => $lastlink, png => $png};
}

sub _log_snippet {
    my ($self, $file, $offset_name) = @_;

    my $offset = $self->$offset_name;
    my $fd;
    my %ret;
    return \%ret unless open($fd, '<:raw', $file);
    sysseek($fd, $offset, Fcntl::SEEK_SET);    # FIXME: handle error?
    if (defined sysread($fd, my $buf = '', 100000)) {
        $ret{offset} = $offset;
        $ret{data}   = $buf;
    }
    if (my $new_offset = sysseek($fd, 0, Fcntl::SEEK_CUR)) {
        $self->{"_$offset_name"} = $new_offset;
    }
    close($fd);
    return \%ret;
}

sub _optimize_image {
    my ($image) = @_;
    log_debug("Optimizing $image");
    {
        # treat as "best-effort". If optipng is not found, ignore
        no warnings;
        system('optipng', '-quiet', '-o2', $image);
    }
    return undef;
}

sub _ignore_known_images {
    my ($self, $known_images) = @_;
    $self->{_known_images} = $known_images if ref $known_images eq 'ARRAY';
    my $images_to_send = $self->images_to_send;
    delete $images_to_send->{$_} for @{$self->known_images};
    return undef;
}

sub _ignore_known_files {
    my ($self, $known_files) = @_;
    $self->{_known_files} = $known_files if ref $known_files eq 'ARRAY';
    my $files_to_send = $self->files_to_send;
    delete $files_to_send->{$_} for @{$self->known_files};
    return undef;
}

1;
