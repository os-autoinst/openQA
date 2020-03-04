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

package OpenQA::Worker::Job;
use Mojo::Base 'Mojo::EventEmitter';

use OpenQA::Jobs::Constants;
use OpenQA::Worker::Engines::isotovideo;
use OpenQA::Worker::Isotovideo::Client;
use OpenQA::Utils qw(log_error log_warning log_debug log_info wait_with_progress);

use Digest::MD5;
use Fcntl;
use POSIX 'strftime';
use File::Basename 'basename';
use File::Which 'which';
use MIME::Base64;
use Mojo::JSON 'decode_json';
use Mojo::File 'path';
use Try::Tiny;

# define attributes for public properties
has 'worker';
has 'client';
has 'isotovideo_client' => sub { OpenQA::Worker::Isotovideo::Client->new(job => shift) };
has 'developer_session_running';
has 'upload_results_interval';

use constant AUTOINST_STATUSFILE => 'autoinst-status.json';

# define accessors for public read-only properties
sub status                    { shift->{_status} }
sub setup_error               { shift->{_setup_error} }
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
    $self->{_status}                 = 'new';
    $self->{_id}                     = $job_info->{id};
    $self->{_info}                   = $job_info;
    $self->{_livelog_viewers}        = 0;
    $self->{_autoinst_log_offset}    = 0;
    $self->{_serial_log_offset}      = 0;
    $self->{_serial_terminal_offset} = 0;
    $self->{_images_to_send}         = {};
    $self->{_files_to_send}          = [];
    $self->{_known_images}           = [];
    $self->{_last_screenshot}        = '';
    $self->{_current_test_module}    = undef;
    $self->{_progress_info}          = {};
    $self->{_engine}                 = undef;
    $self->{_is_uploading_results}   = 0;
    return $self;
}

sub DESTROY {
    my ($self) = @_;
    return if ${^GLOBAL_PHASE} eq 'DESTRUCT';

    $self->_remove_timer;
}

sub _remove_timer {
    my ($self) = @_;

    for my $timer_name (qw(_upload_results_timer _timeout_timer)) {
        if (my $timer_id = delete $self->{$timer_name}) {
            Mojo::IOLoop->remove($timer_id);
        }
    }
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
    if (!$id || !defined $info || ref $info ne 'HASH') {
        die 'attempt to accept job without ID and job info';
    }
    if ($self->status ne 'new') {
        die 'attempt to accept job which is not newly initialized';
    }
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
                reason => 'api-failure',
            });
    }

    $websocket_connection->on(
        finish => sub {
            # note: If the websocket connection goes down this is not critical to the job execution.
            #       However, if it goes down before we can send the "accepted" message we should scrap the
            #       job and just wait for the next "grab job" message. Otherwise the job would end up in
            #       perpetual 'accepting' state.
            $self->stop('api-failure') if ($self->status eq 'accepting' || $self->status eq 'new');
        });
    $websocket_connection->send(
        {json => {type => 'accepted', jobid => $self->id}},
        sub {
            $self->_set_status(accepted => {});
        });
}

sub start {
    my ($self) = @_;

    my $id   = $self->id;
    my $info = $self->info;
    if (!$id || !defined $info || ref $info ne 'HASH') {
        die 'attempt to start job without ID and job info';
    }
    if ($self->status ne 'accepted') {
        die 'attempt to start job which is not accepted';
    }

    $self->_set_status(setup => {});

    # update settings received from web UI with worker-specific stuff
    my $worker                 = $self->worker;
    my $job_settings           = $self->info->{settings} // {};
    my $global_worker_settings = $worker->settings->global_settings;
    delete $job_settings->{GENERAL_HW_CMD_DIR};
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

    # compute max job time (by default 2 hours)
    my $max_job_time = $job_settings->{MAX_JOB_TIME} // 7200;
    if (my $timeout_scale = $job_settings->{TIMEOUT_SCALE}) {
        $max_job_time *= $timeout_scale;
    }

    # set base dir to the one assigned with web UI
    $ENV{OPENQA_SHAREDIR} = $client->working_directory;

    # start isotovideo
    # FIXME: isotovideo.pm could be a class inheriting from Job.pm or simply be merged
    my $engine      = OpenQA::Worker::Engines::isotovideo::engine_workit($self);
    my $setup_error = $engine->{error};
    if (!$setup_error && ($engine->{child}->errored || !$engine->{child}->is_running)) {
        $setup_error = 'isotovideo can not be started';
    }
    if ($self->{_setup_error} = $setup_error) {
        # let the IO loop take over if the job has been stopped during setup
        # notes: - Stop has already been called at this point and async code for stopping is setup to run
        #          on the event loop.
        #        - This can happen if stop is called from an interrupt.
        return undef if $self->is_stopped_or_stopping;

        log_error("Unable to setup job $id: $setup_error");
        return $self->stop('setup failure');
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

    # kill isotovideo if timeout has been exceeded
    $self->{_timeout_timer} = Mojo::IOLoop->timer(
        $max_job_time => sub {
            # prevent to determine status of job from exit_status
            eval {
                if (my $child = $engine->{child}) {
                    $child->session->_protect(
                        sub {
                            $child->unsubscribe('collected');
                        });
                }
            };
            # abort job if it takes too long
            $self->_remove_timer;
            $self->stop('timeout');
        });

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
    $self->_stop_step_6_finalize($reason, {result => OpenQA::Jobs::Constants::SKIPPED});
}

sub stop {
    my ($self, $reason) = @_;
    $reason //= '';

    # ignore calls to stop if already stopped or stopping
    # note: This method might be called at any time (including when an interrupted happens).
    return undef if $self->is_stopped_or_stopping;

    my $status = $self->status;
    if ($status ne 'setup' && $status ne 'running') {
        $self->_set_status(stopped => {reason => $reason});
        return undef;
    }

    $self->_set_status(stopping => {reason => $reason});
    $self->_remove_timer;
    if ($self->{_is_uploading_results}) {
        $self->once(
            uploading_results_concluded => sub {
                $self->_stop_step_1_init($reason);
            });
    }
    else {
        $self->_stop_step_1_init($reason);
    }
}

sub _stop_step_1_init {
    my ($self, $reason) = @_;

    if ($reason eq 'scheduler_abort') {
        $self->_stop_step_3_announce(
            $reason,
            sub {
                $self->_stop_step_4_kill($reason);
                $self->_stop_step_6_finalize($reason);
            });
        return;
    }

    $self->_stop_step_2_post_status(
        $reason,
        sub {
            $self->_stop_step_3_announce(
                $reason,
                sub {
                    $self->_stop_step_4_kill($reason);
                    $self->_stop_step_5_upload(
                        $reason,
                        sub {
                            my ($params_for_finalize, $duplication_res) = @_;
                            my $duplication_failed = defined $duplication_res && !$duplication_res;
                            $self->_stop_step_6_finalize($duplication_failed ? 'api-failure' : $reason,
                                $params_for_finalize);
                        });
                });
        });
}

sub _stop_step_2_post_status {
    my ($self, $reason, $callback) = @_;

    my $job_id = $self->id;
    my $client = $self->client;
    $client->send(
        post => "jobs/$job_id/status",
        json => {
            status => {
                uploading => 1,
                worker_id => $client->worker_id,
            },
        },
        callback => $callback,
    );
}

sub _stop_step_3_announce {
    my ($self, $reason, $callback) = @_;

    # skip if isotovideo not running anymore (e.g. when isotovideo just exited on its own)
    return Mojo::IOLoop->next_tick($callback) unless $self->is_backend_running;

    $self->isotovideo_client->stop_gracefully($reason, $callback);
}

sub _stop_step_4_kill {
    my ($self, $reason) = @_;

    $self->kill;
}

sub _stop_step_5_upload {
    my ($self, $reason, $callback) = @_;

    my $job_id  = $self->id;
    my $pooldir = $self->worker->pool_directory;

    # add notes
    log_info("+++ worker notes +++",                             channels => 'autoinst');
    log_info(sprintf("End time: %s", strftime("%F %T", gmtime)), channels => 'autoinst');
    log_info("Result: $reason",                                  channels => 'autoinst');

    # upload logs and assets
    if ($reason ne 'quit' && $reason ne 'abort' && $reason ne 'api-failure') {

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
                        $reason = 'api-failure';
                        last;
                    }
                }

                # upload assets created by successful jobs
                if ($reason eq 'done' || $reason eq 'cancel') {
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
                            $reason = 'api-failure';
                            last;
                        }
                    }
                }

                my @other
                  = qw(video.ogv video_time.vtt vars.json serial0 autoinst-log.txt serial_terminal.txt virtio_console.log worker-log.txt virtio_console1.log);
                for my $other (@other) {
                    my $file = "$pooldir/$other";
                    next unless -e $file;

                    # replace some file names
                    my $ofile = $file;
                    $ofile =~ s/serial0/serial0.txt/;
                    $ofile =~ s/virtio_console.log/serial_terminal.txt/;

                    my %upload_parameter = (file => {file => $file, filename => basename($ofile)});
                    if (!$self->_upload_log_file_or_asset(\%upload_parameter)) {
                        $reason = 'api-failure';
                        last;
                    }
                }
                return $reason;
            },
            sub {
                my ($subprocess, $err, $reason) = @_;
                log_error("Upload subprocess error: $err") if $err;
                $self->_stop_step_5_1_upload($reason // 'api-failure', $callback);
            });
    }

    else {
        Mojo::IOLoop->next_tick(sub { $self->_stop_step_5_1_upload($reason, $callback) });
    }
}

sub _stop_step_5_1_upload {
    my ($self, $reason, $callback) = @_;

    my $job_id = $self->id;

    # do final status upload for selected reasons
    if ($reason eq 'obsolete') {
        log_debug("Setting job $job_id to incomplete (obsolete)");
        return $self->_upload_results(
            sub { $callback->({result => OpenQA::Jobs::Constants::INCOMPLETE, newbuild => 1}) });
    }
    if ($reason eq 'cancel') {
        log_debug("Setting job $job_id to incomplete (cancel)");
        return $self->_upload_results(sub { $callback->({result => OpenQA::Jobs::Constants::INCOMPLETE}) });
    }
    if ($reason eq 'done') {
        log_debug("Setting job $job_id to done");
        return $self->_upload_results(sub { $callback->(); });
    }

    if ($reason eq 'api-failure') {
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
    if ($reason eq 'timeout') {
        log_warning("Job $job_id stopped because it exceeded MAX_JOB_TIME");
        $result = OpenQA::Jobs::Constants::TIMEOUT_EXCEEDED;
    }
    else {
        log_debug("Job $job_id stopped as incomplete");
        $result = OpenQA::Jobs::Constants::INCOMPLETE;
    }

    # do final status upload and set result unless abort reason is "quit"
    if ($reason ne 'quit') {
        return $self->_upload_results(sub { $callback->({result => $result}) });
    }

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
            $self->_upload_results(
                sub {
                    $callback->({result => OpenQA::Jobs::Constants::INCOMPLETE}, $duplication_res);
                });
        });
}

sub _format_reason {
    my ($self, $result, $reason) = @_;
    return undef unless $reason ne 'done' && (!defined $result || $result ne $reason);

    if ($reason eq 'setup failure') {
        return "setup failure: $self->{_setup_error}";
    }
    elsif ($reason eq 'api-failure') {
        if (my $last_client_error = $self->client->last_error) {
            return "api failure: $last_client_error";
        }
        else {
            return 'api failure';
        }
    }
    elsif ($reason eq 'cancel') {
        return undef;    # the result is sufficient here
    }
    else {
        return $reason;
    }
}

sub _set_job_done {
    my ($self, $reason, $params, $callback) = @_;

    # pass the reason if it is an additional specification of the result
    my $formatted_reason = $self->_format_reason($params->{result}, $reason);
    $params->{reason} = $formatted_reason if defined $formatted_reason;

    my $job_id = $self->id;
    return $self->client->send(
        post          => "jobs/$job_id/set_done",
        params        => $params,
        non_critical  => 1,
        ignore_errors => 1,
        callback      => $callback,
    );
}

sub _stop_step_6_finalize {
    my ($self, $reason, $params) = @_;

    $self->_set_job_done(
        $reason, $params,
        sub {
            $self->_set_status(stopped => {reason => $reason});
        });

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
    else {
        log_debug("New livelog viewer, $livelog_viewers viewers in total now");
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
    if ($livelog_viewers >= 1) {
        $livelog_viewers -= 1;
    }
    if ($livelog_viewers == 0) {
        log_debug('Stopping livelog');
        unlink "$pooldir/live_log";
    }
    else {
        log_debug("Livelog viewer left, $livelog_viewers remaining");
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
    if (!defined $worker_id || !defined $job_id) {
        die 'attempt to post setup status without worker and/or job ID';
    }

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

    if ($self->livelog_viewers >= 1) {
        $interval = 1;
    }
    else {
        $interval = 10;
    }

    $self->upload_results_interval($interval);
    return $interval;
}

sub _upload_results {
    my ($self, $callback) = @_;

    # FIXME: This is partially blocking and partially async. It would be best to make everything blocking
    #        and make it a Minion job or to make everything async (likely harder).

    # ensure an ongoing timer is cancelled in case upload_results has been called manually
    if (my $upload_results_timer = delete $self->{_upload_results_timer}) {
        Mojo::IOLoop->remove($upload_results_timer);
    }

    # return if job setup is insufficient
    if (!$self->isotovideo_client->url || !$self->client->worker_id) {
        log_warning('Unable to upload results of the job because no command server URL or worker ID have been set.');
        $self->emit(uploading_results_concluded => {});
        return Mojo::IOLoop->next_tick($callback);
    }

    # determine wheter this is the final upload
    # note: This function is also called when stopping the current job. We can't query isotovideo
    #       anymore in this case and API calls must be treated as non-critical to prevent the usual
    #       error handling.
    my $is_final_upload = $self->is_stopped_or_stopping;
    $self->{_is_uploading_results} = 1;

    $self->_upload_results_step_0_prepare($is_final_upload, $callback);
}

sub _upload_results_step_0_prepare {
    my ($self, $is_final_upload, $callback) = @_;

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

    my $test_status = {};
    if (-r $status_file) {
        $test_status = decode_json(path($status_file)->slurp);
    }

    my $running_or_finished = ($test_status->{status} || '') =~ m/^(?:running|finished)$/;
    my $running_test        = $test_status->{current_test} || '';
    $status{test_execution_paused} = $test_status->{test_execution_paused} // 0;

    # determine up to which module the results should be uploaded
    my $current_test_module = $self->current_test_module;
    my $upload_up_to;
    if ($is_final_upload || $running_or_finished) {
        my @file_info = stat $self->_result_file_path('test_order.json');
        my $test_order;
        if (   !$current_test_module
            or !$file_info[9]
            or $file_info[9] != $self->{_test_order_mtime}
            or !$file_info[7]
            or $file_info[7] != $self->{_test_order_fsize})
        {
            log_info('Test schedule has changed, reloading test_order.json') if $self->{_test_order_mtime};
            $test_order                = $self->_read_json_file('test_order.json');
            $status{test_order}        = $test_order;
            $self->{_test_order}       = $test_order;
            $self->{_test_order_mtime} = $file_info[9];
            $self->{_test_order_fsize} = $file_info[7];
        }
        if (!$current_test_module) {    # first test (or already after the last!)
            if (!$test_order) {
                # FIXME: It would still make sense to upload other files.
                $self->stop('no tests scheduled');    # will be delayed until upload has been concluded
                $self->emit(uploading_results_concluded => {});
                return Mojo::IOLoop->next_tick($callback);
            }
        }
        elsif ($current_test_module ne $running_test) {    # next test
            $upload_up_to = $current_test_module;
        }
        $self->{_current_test_module} = $current_test_module = $running_test;
    }

    # adjust $upload_up_to to handle special cases
    if ($is_final_upload) {
        # try to upload everything at the end, in case we missed the last
        # $test_status->{current_test}
        $upload_up_to = '';
    }
    elsif ($status{test_execution_paused}) {
        # upload up to the current module when paused so it is possible to open the needle editor
        $upload_up_to = $current_test_module;
    }

    # upload all results up to $upload_up_to
    if (defined($upload_up_to)) {
        $status{result} = $self->_read_result_file($upload_up_to, $status{test_order} //= []);
    }

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
    $status{result}->{$current_test_module}->{result} = 'running' if ($current_test_module);

    # define steps for uploading status to web UI
    return $self->_upload_results_step_1_post_status(
        \%status,
        $is_final_upload,
        sub {
            my ($status_post_res) = @_;

            # handle error occurred when posting the status
            if (!$status_post_res) {
                if ($is_final_upload) {
                    log_error('Unable to make final image uploads. Maybe the web UI considers this job already dead.');
                }
                else {
                    log_error('Aborting job because web UI doesn\'t accept new images anymore'
                          . ' (likely considers this job dead)');
                    $self->stop('api-failure');    # will be delayed until upload has been concluded via *_finalize()
                }
                return $self->_upload_results_step_3_finalize($is_final_upload, $callback);
            }

            # ignore known images
            my $known_images = $status_post_res->{known_images};
            if (ref $known_images eq 'ARRAY') {
                $self->{_known_images} = $known_images;
            }
            $self->_ignore_known_images;

            # inform liveviewhandler about upload progress if developer session opened
            return $self->post_upload_progress_to_liveviewhandler(
                $upload_up_to,
                $is_final_upload,
                sub {

                    # upload images (not an async operation)
                    $self->_upload_results_step_2_upload_images(
                        sub {

                            # inform liveviewhandler about upload progress if developer session opened
                            return $self->post_upload_progress_to_liveviewhandler(
                                $upload_up_to,
                                $is_final_upload,
                                sub {
                                    $self->_upload_results_step_3_finalize($is_final_upload, $callback);
                                });
                        });

                });
        });
}

sub _upload_results_step_1_post_status {
    my ($self, $status, $is_final_upload, $callback) = @_;

    my $job_id = $self->id;
    $self->client->send(
        post         => "jobs/$job_id/status",
        json         => {status => $status},
        non_critical => $is_final_upload,
        callback     => $callback,
    );
}

sub _upload_results_step_2_upload_images {
    my ($self, $callback) = @_;

    Mojo::IOLoop->subprocess(
        sub {
            my $job_id = $self->id;
            my $client = $self->client;

            my $images_to_send = $self->images_to_send;
            for my $md5 (keys %$images_to_send) {
                my $file = $images_to_send->{$md5};
                $self->_optimize_image($self->_result_file_path($file));

                $client->send_artefact(
                    $job_id => {
                        file => {
                            file     => $self->_result_file_path($file),
                            filename => $file
                        },
                        image => 1,
                        thumb => 0,
                        md5   => $md5
                    });

                my $thumb = $self->_result_file_path(".thumbs/$file");
                if (-f $thumb) {
                    $self->_optimize_image($thumb);
                    $client->send_artefact(
                        $job_id => {
                            file => {
                                file     => $thumb,
                                filename => $file
                            },
                            image => 1,
                            thumb => 1,
                            md5   => $md5
                        });
                }
            }

            for my $file (@{$self->files_to_send}) {
                $client->send_artefact(
                    $job_id => {
                        file => {
                            file     => $self->_result_file_path($file),
                            filename => $file,
                        },
                        image => 0,
                        thumb => 0,
                    });
            }
        },
        sub {
            my ($subprocess, $err) = @_;
            log_error("Upload images subprocess error: $err") if $err;
            $self->{_images_to_send} = {};
            $self->{_files_to_send}  = [];
            $callback->();
        });
}

sub _upload_results_step_3_finalize {
    my ($self, $is_final_upload, $callback) = @_;

    # continue sending status updates
    unless ($is_final_upload) {
        my $interval = $self->_calculate_upload_results_interval;
        $self->{_upload_results_timer} = Mojo::IOLoop->timer(
            $interval,
            sub {
                $self->_upload_results(sub { });
            });
    }

    $self->{_is_uploading_results} = 0;
    $self->emit(uploading_results_concluded => {});
    Mojo::IOLoop->next_tick($callback);
}

sub post_upload_progress_to_liveviewhandler {
    my ($self, $upload_up_to, $is_final_upload, $callback) = @_;

    if ($is_final_upload || !$self->developer_session_running) {
        return Mojo::IOLoop->next_tick($callback);
    }

    my $current_test_module = $self->current_test_module;
    my %new_progress_info   = (
        upload_up_to                => $upload_up_to,
        upload_up_to_current_module => $current_test_module && $upload_up_to && $current_test_module eq $upload_up_to,
        outstanding_files           => scalar(@{$self->files_to_send}),
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
    if (!$progress_changed) {
        return Mojo::IOLoop->next_tick($callback);
    }
    $self->{_progress_info} = \%new_progress_info;

    my $job_id = $self->id;
    $self->client->send(
        post => "/liveviewhandler/api/v1/jobs/$job_id/upload_progress",
        service_port_delta => 2,                     # liveviewhandler is supposed to run on web UI port + 2
        json               => \%new_progress_info,
        non_critical       => 1,
        callback           => sub {
            my ($res) = @_;
            if (!$res) {
                log_warning('Failed to post upload progress to liveviewhandler.');
            }
            $callback->($res);
        });
}

sub _upload_log_file_or_asset {
    my ($self, $upload_parameter) = @_;

    my $filename = $upload_parameter->{file}->{filename};
    my $file     = $upload_parameter->{file}->{file};
    my $is_asset = $upload_parameter->{asset};
    log_info("Uploading $filename", channels => ['worker', 'autoinst'], default => 1);

    if ($is_asset) {
        return $self->_upload_asset($upload_parameter);
    }
    else {
        return $self->_upload_log_file($upload_parameter);
    }
}

sub _log_upload_error {
    my ($filename, $res) = @_;

    return undef unless my $err = $res->error;

    my $error_type = $err->{code} ? "$err->{code} response" : 'connection error';
    log_error(
        "Error uploading $filename: $error_type: $err->{message}",
        channels => ['autoinst', 'worker'],
        default  => 1
    );
    return 1;
}

sub _upload_asset {
    my ($self, $upload_parameter) = @_;

    my $job_id     = $self->id;
    my $filename   = $upload_parameter->{file}->{filename};
    my $file       = $upload_parameter->{file}->{file};
    my $chunk_size = $self->worker->settings->global_settings->{UPLOAD_CHUNK_SIZE} // 1000000;
    my $ua         = $self->client->ua;
    my $error;

    log_info("Uploading $filename using multiple chunks", channels => ['worker'], default => 1);

    $ua->upload->once(
        'upload_chunk.prepare' => sub {
            my ($self, $pieces) = @_;
            log_info("$filename: " . $pieces->size() . " chunks",   channels => ['worker'], default => 1);
            log_info("$filename: chunks of $chunk_size bytes each", channels => ['worker'], default => 1);
        });
    my $t_start;
    $ua->upload->on('upload_chunk.start' => sub { $t_start = time() });
    $ua->upload->on(
        'upload_chunk.finish' => sub {
            my ($self, $piece) = @_;
            my $spent  = (time() - $t_start) || 1;
            my $kbytes = ($piece->end - $piece->start) / 1024;
            my $speed  = sprintf("%.3f", $kbytes / $spent);
            log_info(
                "$filename: Processing chunk " . $piece->index() . "/" . $piece->total . " avg speed ~${speed}KB/s",
                channels => ['worker'],
                default  => 1
            );
        });

    $ua->upload->on(
        'upload_chunk.response' => sub {
            my ($self, $res) = @_;
            if ($res->res->is_server_error) {
                log_error($res->res->json->{error}, channels => ['autoinst', 'worker'], default => 1)
                  if $res->res->json && $res->res->json->{error};
                my $msg = "Failed uploading chunk";
                log_error($msg, channels => ['autoinst', 'worker'], default => 1);
            }
            _log_upload_error($filename, $res);
        });
    $ua->upload->on(
        'upload_chunk.fail' => sub {
            my ($self, $res, $chunk) = @_;
            log_error(
                "Upload failed for chunk " . $chunk->index,
                channels => ['autoinst', 'worker'],
                default  => 1
            );
            sleep 5;    # do not choke webui
        });

    $ua->upload->once(
        'upload_chunk.error' => sub {
            $error = pop();
            log_error(
                "Upload failed, and all retry attempts have been exhausted",
                channels => ['autoinst', 'worker'],
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
            });
    };
    log_error($@, channels => ['autoinst', 'worker'], default => 1) if $@;

    $ua->upload->unsubscribe($_)
      for qw(upload_chunk.request_err upload_chunk.error upload_chunk.fail),
      qw( upload_chunk.response upload_chunk.start upload_chunk.finish upload_chunk.prepare);

    return 0 if $@ || $error;
    return 1;
}

sub _upload_log_file {
    my ($self, $upload_parameter) = @_;

    my $job_id                = $self->id;
    my $filename              = $upload_parameter->{file}->{filename};
    my $regular_upload_failed = 0;
    my $retry_counter         = 5;
    my $retry_limit           = 5;
    my $tics                  = 5;
    my $res;
    my $client = $self->client;
    my $url    = $client->url;
    my $ua     = $client->ua;

    # FIXME: The version before this refactoring stated that it would be required
    # to open and close the log here as one of the files might actually be autoinst-log.txt.
    # However, this was not implemented.

    while (1) {
        my $ua_url = $url->clone;
        $ua_url->path("jobs/$job_id/artefact");
        my $tx = $ua->build_tx(POST => $ua_url => form => $upload_parameter);

        if ($regular_upload_failed) {
            log_warning(
                sprintf(
                    'Upload attempts remaining: %s/%s for %s, in %s seconds',
                    $retry_counter--, $retry_limit, $filename, $tics
                ));
            wait_with_progress($tics);
        }

        $res = $ua->start($tx);

        # upload known server failures (instead of anything that's not 200)
        if ($res->res->is_server_error) {
            log_error($res->res->json->{error}, channels => ['autoinst', 'worker'], default => 1)
              if $res->res->json && $res->res->json->{error};

            $regular_upload_failed = 1;
            next if $retry_counter;

            # Just return if all upload retries have failed
            # this will cause the next group of uploads to be triggered
            my $msg = "All $retry_limit upload attempts have failed for $filename";
            log_error($msg, channels => ['autoinst', 'worker'], default => 1);
            return 0;
        }
        last;
    }

    return 0 if _log_upload_error($filename, $res);
    return 1;
}

sub _read_json_file {
    my ($self, $name) = @_;

    my $fn = $self->_result_file_path($name);
    local $/;
    my $fh;
    if (!open($fh, '<', $fn)) {
        log_debug("Unable to read $name: $!");
        return undef;
    }
    my $json = {};
    eval { $json = decode_json(<$fh>); };
    log_warning("os-autoinst didn't write proper $fn") if $@;
    close($fh);
    return $json;
}

sub _read_result_file {
    my ($self, $upload_up_to, $extra_test_order) = @_;

    my %ret;

    # upload all results not yet uploaded - and stop at $upload_up_to
    # if $upload_up_to is empty string, then upload everything
    my $test_order = $self->test_order;
    while ($test_order && (my $remaining_test_count = scalar(@$test_order))) {
        my $test   = $test_order->[0]->{name};
        my $result = $self->_read_module_result($test);

        my $current_test_module         = $self->current_test_module;
        my $is_last_test_to_be_uploaded = $remaining_test_count == 1 || $test eq $upload_up_to;
        my $test_not_running            = !$current_test_module || $test ne $current_test_module;
        my $test_is_completed           = !$is_last_test_to_be_uploaded || $test_not_running;
        if ($test_is_completed) {
            # remove completed tests from @$test_order so we don't upload those results twice
            shift(@$test_order);
        }

        last unless ($result);
        $ret{$test} = $result;

        if ($result->{extra_test_results}) {
            for my $extra_test (@{$result->{extra_test_results}}) {
                my $extra_result = $self->_read_module_result($extra_test->{name});
                next unless $extra_result;
                $ret{$extra_test->{name}} = $extra_result;
            }
            push @{$extra_test_order}, @{$result->{extra_test_results}};
        }

        last if $is_last_test_to_be_uploaded;
    }
    return \%ret;
}

sub _read_module_result {
    my ($self, $test) = @_;

    my $result = $self->_read_json_file("result-$test.json");
    return unless $result;

    my $images_to_send = $self->images_to_send;
    my $files_to_send  = $self->files_to_send;
    my $details        = ref($result->{details}) eq 'HASH' ? $result->{details}->{results} : $result->{details};
    for my $d (@$details) {
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
                push(@$files_to_send, $file);
            }
        }
    }
    return $result;
}

sub _calculate_file_md5 {
    my ($self, $file) = @_;

    my $c   = path($self->worker->pool_directory, $file)->slurp;
    my $md5 = Digest::MD5->new;
    $md5->add($c);
    return $md5->clone->hexdigest;
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
    unless (open($fd, '<:raw', $file)) {
        return \%ret;
    }

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
    my ($self, $image) = @_;

    if (which('optipng')) {
        log_debug("Optimizing $image");
        system('optipng', '-quiet', '-o2', $image);
    }
    return undef;
}

sub _ignore_known_images {
    my ($self) = @_;

    my $images_to_send = $self->images_to_send;
    for my $md5 (@{$self->known_images}) {
        delete $images_to_send->{$md5};
    }
    return undef;
}

1;
