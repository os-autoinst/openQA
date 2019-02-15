# Copyright (C) 2015-2019 SUSE LLC
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

package OpenQA::Worker::Jobs;

use 5.018;
use strict;
use warnings;
use feature 'state';

use OpenQA::Worker::Common;
use OpenQA::Worker::Pool 'clean_pool';
use OpenQA::Worker::Engines::isotovideo;
use OpenQA::Utils
  qw(wait_with_progress log_error log_warning log_debug log_info add_log_channel remove_log_channel get_channel_handle);
use POSIX qw(strftime SIGTERM);
use File::Copy qw(copy move);
use File::Path 'remove_tree';
use Mojo::JSON 'decode_json';
use Fcntl;
use MIME::Base64;
use File::Basename 'basename';
use File::Which 'which';
use Try::Tiny;
use Mojo::File 'path';
use Mojo::IOLoop;
use OpenQA::File;
use OpenQA::Events;
use Mojo::IOLoop::ReadWriteProcess;
use POSIX ':sys_wait_h';
use Exporter 'import';

our @EXPORT = qw(start_job stop_job check_job backend_running);

my $worker;
my $log_offset             = 0;
my $serial_offset          = 0;
my $serial_terminal_offset = 0;
my $max_job_time           = 7200;    # 2h
my $current_running;
my $test_order;
my $stop_job_running;
my $update_status_running;

my $boundary = '--a_sTrinG-thAt_wIll_n0t_apPEar_iN_openQA_uPloads-61020111';

my $tosend_images         = {};
my $known_images          = undef;
my $tosend_files          = [];
my $progress_info         = {};
my $has_developer_session = 0;

our $do_livelog;

## Job management
sub _kill_worker($) {
    my ($worker) = @_;
    return if !$worker->{child} || !$worker->{child}->is_running;
    $worker->{child}->stop;
}

# method prototypes
sub start_job;

sub is_upload_status_running {
    return $update_status_running;
}

sub check_job {
    my (@todo) = @_;
    state $check_job_running;
    return unless @todo;

    my $host = shift @todo;
    return if $check_job_running->{$host};
    return unless my $workerid = $hosts->{$host}{workerid};
    return if $job;

    $check_job_running->{$host} = 1;
    log_debug("checking for job with webui $host");
    api_call(
        'post',
        "workers/$workerid/grab_job",
        params   => $worker_caps,
        host     => $host,
        callback => sub {
            my ($res) = @_;
            return unless ($res);
            $job = $res->{job};
            if ($job && $job->{id}) {
                Mojo::IOLoop->next_tick(sub { start_job($host) });
            }
            else {
                $job = undef;
                Mojo::IOLoop->next_tick(sub { check_job(@todo) });
            }
            $check_job_running->{$host} = 0;
        });
}

sub stop_job {
    my ($aborted, $job_id, $host) = @_;

    # skip if no job running or stop_job has already been called; stop event loop "forcefully" if called to quit
    if (!$job || $stop_job_running) {
        my $reason = $aborted ? $aborted : 'no reason';
        if ($stop_job_running) {
            log_debug("stop_job called after job has already been asked to stop (reason: $reason)");
        }
        else {
            log_debug("stop_job called while no job was running (reason: $reason)");
        }
        Mojo::IOLoop->stop if $aborted eq 'quit';
        return;
    }

    # skip if (already) executing a different job
    return if $job_id && $job_id != $job->{id};

    $job_id = $job->{id};
    $host //= $current_host;

    log_debug("stop_job $aborted");
    $stop_job_running = 1;

    # stop all job related timers
    remove_timer('update_status');
    remove_timer('job_timeout');

    # postpone stopping until possibly ongoing status update is concluded
    my $stop_job_check_status;
    $stop_job_check_status = sub {
        if (!$update_status_running) {
            _stop_job_init($aborted, $job_id, $host);
            return undef;
        }
        log_debug('postpone stopping until ongoing status update is concluded');
        Mojo::IOLoop->timer(1 => $stop_job_check_status);
    };
    $stop_job_check_status->();
}

sub verify_job {
    return 1 if $job && ref($job) eq "HASH";
    return 0;
}

sub _reset_state {
    local $@;
    eval { log_info('cleaning up ' . $job->{settings}->{NAME}) if verify_job && exists $job->{settings}->{NAME}; };
    log_error($@) if $@;
    clean_pool;
    $job              = undef;
    $worker           = undef;
    $stop_job_running = 0;
    $current_host     = undef;
    OpenQA::Events->singleton->emit("stop_job");
}

sub _upload_state {
    my ($job_id, $form) = @_;
    my $ua_url = $hosts->{$current_host}{url}->clone;
    $ua_url->path("jobs/$job_id/upload_state");
    $hosts->{$current_host}{ua}->post($ua_url => form => $form);
    return 1;
}

sub _multichunk_upload {
    my ($job_id, $form) = @_;
    my $filename   = $form->{file}->{filename};
    my $file       = $form->{file}->{file};
    my $is_asset   = $form->{asset};
    my $chunk_size = $worker_settings->{UPLOAD_CHUNK_SIZE} // 1000000;
    my $client     = $hosts->{$current_host}{ua};
    my $e;

    log_info("$filename multi-chunk upload", channels => ['worker'], default => 1);

    $client->upload->once(
        'upload_chunk.prepare' => sub {
            my ($self, $pieces) = @_;
            log_info("$filename: " . $pieces->size() . " chunks",   channels => ['worker'], default => 1);
            log_info("$filename: chunks of $chunk_size bytes each", channels => ['worker'], default => 1);
        });
    my $t_start;
    $client->upload->on('upload_chunk.start' => sub { $t_start = time() });
    $client->upload->on(
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

    $client->upload->on(
        'upload_chunk.response' => sub {
            my ($self, $res) = @_;
            if ($res->res->is_server_error) {
                log_error($res->res->json->{error}, channels => ['autoinst', 'worker'], default => 1)
                  if $res->res->json && $res->res->json->{error};
                my $msg = "Failed uploading chunk";
                log_error($msg, channels => ['autoinst', 'worker'], default => 1);
            }

            if (my $err = $res->error) {
                my $msg;
                if ($err->{code}) {
                    $msg = sprintf "ERROR %s: $err->{code} response: $err->{message}\n", $filename;
                }
                else {
                    $msg = sprintf "ERROR %s: Connection error: $err->{message}\n", $filename;
                }
                log_error($msg, channels => ['autoinst', 'worker'], default => 1);
            }
        });
    $client->upload->on(
        'upload_chunk.fail' => sub {
            my ($self, $res, $chunk) = @_;
            log_error(
                "Upload failed for chunk " . $chunk->index,
                channels => ['autoinst', 'worker'],
                default  => 1
            );
            sleep 5;    # do not choke webui
        });

    $client->upload->once(
        'upload_chunk.error' => sub {
            $e = pop();
            log_error(
                "Upload failed, and all retry attempts have been exhausted",
                channels => ['autoinst', 'worker'],
                default  => 1
            );
        });

    local $@;
    eval {
        $client->upload->asset(
            $job_id => {
                file       => $file,
                name       => $filename,
                asset      => $form->{asset},
                chunk_size => $chunk_size
            });
    };
    log_error($@, channels => ['autoinst', 'worker'], default => 1) if $@;

    $client->upload->unsubscribe($_)
      for qw(upload_chunk.request_err upload_chunk.error upload_chunk.fail),
      qw( upload_chunk.response upload_chunk.start upload_chunk.finish upload_chunk.prepare);

    return 0 if $@ || $e;
    return 1;
}

sub _upload {
    my ($job_id, $form) = @_;
    my $filename = $form->{file}->{filename};
    my $file     = $form->{file}->{file};
    # we need to open and close the log here as one of the files
    # might actually be autoinst-log.txt

    my $regular_upload_failed = 0;
    my $retry_counter         = 5;
    my $retry_limit           = 5;
    my $tics                  = 5;
    my $res;

    while (1) {
        my $ua_url = $hosts->{$current_host}{url}->clone;
        $ua_url->path("jobs/$job_id/artefact");

        my $tx = $hosts->{$current_host}{ua}->build_tx(POST => $ua_url => form => $form);

        if ($regular_upload_failed) {
            log_warning(
                sprintf(
                    'Upload attempts remaining: %s/%s for %s, in %s seconds',
                    $retry_counter--, $retry_limit, $filename, $tics
                ));
            wait_with_progress($tics);
        }

        $res = $hosts->{$current_host}{ua}->start($tx);

        # Upload known server failures (Instead of anything that's not 200)
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

    if (my $err = $res->error) {
        my $msg;
        if ($err->{code}) {
            $msg = sprintf "ERROR %s: $err->{code} response: $err->{message}\n", $filename;
        }
        else {
            $msg = sprintf "ERROR %s: Connection error: $err->{message}\n", $filename;
        }
        log_error($msg, channels => ['autoinst', 'worker'], default => 1);
        return 0;
    }

    return 1;
}

sub upload {
    my ($job_id, $form) = @_;
    unless (verify_workerid) {
        _reset_state;
        die 'No current_host!';
    }
    my $filename = $form->{file}->{filename};
    my $file     = $form->{file}->{file};
    my $is_asset = $form->{asset};
    log_info("uploading $filename", channels => ['worker', 'autoinst'], default => 1);

    return _upload($job_id, $form) unless $is_asset;
    return _multichunk_upload($job_id, $form);
}

sub _stop_job_init {
    my ($aborted, $job_id, $host) = @_;
    my $workerid = verify_workerid;

    # now tell the webui that we're about to finish, but the following
    # process of killing the backend process and checksums uploads and
    # checksums again can take a long while, so the webui needs to know

    if ($aborted eq "scheduler_abort") {
        log_debug('stop_job called by the scheduler. do not send logs');
        _stop_job_announce(
            $aborted, $job_id,
            sub {
                _kill_worker($worker);
                _reset_state;
            });
        return;
    }

    api_call(
        post => "jobs/$job_id/status",
        json => {
            status => {
                uploading => 1,
                worker_id => $workerid,
            },
        },
        callback => sub {
            _stop_job_announce(
                $aborted, $job_id,
                sub {
                    _stop_job_kill_and_upload($aborted, $job_id, $host);
                });
        },
    );
}

sub _stop_job_announce {
    my ($aborted, $job_id, $callback) = @_;

    my $ua      = Mojo::UserAgent->new(request_timeout => 10);
    my $job_url = $job->{URL};
    return $callback->() unless $job_url;

    try {
        my $url = "$job_url/broadcast";
        my $tx  = $ua->build_tx(
            POST => $url,
            json => {
                stopping_test_execution => $aborted,
            },
        );

        log_info('trying to stop job gracefully by announcing it to command server via ' . $url);
        $ua->start(
            $tx,
            sub {
                my ($ua_from_callback, $tx) = @_;
                my $keep_ref_to_ua = $ua;
                my $res            = $tx->res;

                if (!$res->is_success) {
                    log_error('unable to stop the command server gracefully: ');
                    log_error($res->code ? $res->to_string : 'command server likely not reachable at all');
                }
                $callback->();
            });
    }
    catch {
        log_error('unable to stop the command server gracefully: ' . $_);

        # ensure stopping is proceeded (failing announcement is not critical)
        $callback->();
    };
}

sub _stop_job_kill_and_upload {
    my ($aborted, $job_id, $host) = @_;
    _kill_worker($worker);

    my $name = $job->{settings}->{NAME};
    $aborted ||= 'done';

    my $job_done;    # undef
    log_info("+++ worker notes +++", channels => 'autoinst');
    log_info(sprintf("end time: %s", strftime("%F %T", gmtime)), channels => 'autoinst');
    log_info("result: $aborted", channels => 'autoinst');
    if ($aborted ne 'quit' && $aborted ne 'abort' && $aborted ne 'api-failure') {
        # collect uploaded logs
        my @uploaded_logfiles = glob "$pooldir/ulogs/*";
        for my $file (@uploaded_logfiles) {
            next unless -f $file;

            # don't use api_call as it retries and does not allow form data
            # (refactor at some point)
            unless (
                upload(
                    $job_id,
                    {
                        file => {file => $file, filename => basename($file)},
                        ulog => 1
                    }))
            {
                $aborted = "failed to upload $file";
                last;
            }
        }

        if ($aborted eq 'done' || $aborted eq 'cancel') {
            # job succeeded, upload assets created by the job

          ASSET_UPLOAD: for my $dir (qw(private public)) {
                my @assets = glob "$pooldir/assets_$dir/*";
                for my $file (@assets) {
                    next unless -f $file;
                    unless (
                        upload(
                            $job_id,
                            {
                                file  => {file => $file, filename => basename($file)},
                                asset => $dir
                            }))
                    {
                        $aborted = 'failed to upload asset';
                        last ASSET_UPLOAD;
                    }
                }
            }
        }
        for my $file (qw(video.ogv video_time.vtt vars.json serial0 autoinst-log.txt virtio_console.log worker-log.txt))
        {
            next unless -e $file;
            # default serial output file called serial0
            my $ofile = $file;
            $ofile =~ s/serial0/serial0.txt/;
            $ofile =~ s/virtio_console.log/serial_terminal.txt/;
            unless (
                upload(
                    $job_id,
                    {
                        file => {file => "$pooldir/$file", filename => $ofile}}))
            {
                $aborted = "failed to upload $file";
                last;
            }
        }

        if ($aborted eq 'obsolete') {
            log_debug('setting job ' . $job->{id} . ' to incomplete (obsolete)');
            upload_status(1, sub { _stop_job_finish({result => 'incomplete', newbuild => 1}) });
            $job_done = 1;
        }
        elsif ($aborted eq 'cancel') {
            # not using job_incomplete here to avoid duplicate
            log_debug('setting job ' . $job->{id} . ' to incomplete (cancel)');
            upload_status(1, sub { _stop_job_finish({result => 'incomplete'}) });
            $job_done = 1;
        }
        elsif ($aborted eq 'timeout') {
            log_warning('job ' . $job->{id} . ' spent more time than MAX_JOB_TIME');
        }
        elsif ($aborted eq 'done') {    # not aborted
            log_debug('setting job ' . $job->{id} . ' to done');
            upload_status(1, \&_stop_job_finish);
            $job_done = 1;
        }
        elsif ($aborted eq 'dead_children') {
            log_debug('Dead children found.');

            api_call(
                'post', 'jobs/' . $job->{id} . '/set_done',
                params   => {result => 'incomplete'},
                callback => 'no'
            );
        }
    }
    if (!$job_done && $aborted ne 'api-failure') {
        log_debug(sprintf 'job %d incomplete', $job->{id});
        if ($aborted eq 'quit') {
            log_debug(sprintf "duplicating job %d\n", $job->{id});
            api_call(
                'post',
                'jobs/' . $job->{id} . '/duplicate',
                params   => {dup_type_auto => 1},
                callback => sub {
                    upload_status(1, sub { _stop_job_finish({result => 'incomplete'}, 1) });
                });
        }
        else {
            upload_status(1, sub { _stop_job_finish({result => 'incomplete'}, 0) });
        }
    }
    elsif ($aborted eq 'api-failure') {
        # give the API one last try to incomplete the job at least
        # note: Setting 'ignore_errors' here is important. Otherwise we would endlessly repeat
        #       that API call.
        api_call(
            post          => "jobs/$job->{id}/set_done",
            params        => {result => 'incomplete'},
            ignore_errors => 1,
            callback      => sub {
                _reset_state;
                _stop_accepting_jobs_and_register_again($host);
            },
        );
    }
}

sub _stop_accepting_jobs_and_register_again {
    my ($host_name) = @_;
    my $host = $hosts->{$host_name};

    $host->{accepting_jobs} = 0;
    $host->{timers}{register_worker}
      = add_timer("register_worker-$host_name", 10, sub { register_worker($host_name) }, 1);
}

sub _stop_job_finish {
    my ($params, $quit) = @_;

    # try again in 1 second if still updating status
    if ($update_status_running) {
        log_debug("waiting for update status running: $update_status_running");
        add_timer('', 1, sub { _stop_job_finish($params, $quit) }, 1);
        return;
    }

    api_call(
        post     => "jobs/$job->{id}/set_done",
        params   => $params,
        callback => sub {
            _reset_state;
            Mojo::IOLoop->stop if ($quit);
        },
    );
}

sub copy_job_settings {
    my ($j, $worker_settings) = @_;
    @{$j->{settings}}{keys %$worker_settings} = values %$worker_settings;
}

sub start_job {
    my ($host) = @_;
    return _reset_state unless verify_job;

    # block the job from having dangerous settings (isotovideo specific though)
    # it needs to come from worker_settings
    my $job_settings = $job->{settings};
    delete $job_settings->{GENERAL_HW_CMD_DIR};

    # update settings with worker-specific stuff
    copy_job_settings($job, $worker_settings);
    if ($pooldir) {
        my $fd;
        print $fd, "" if open($fd, '>', "$pooldir/worker-log.txt") or log_error "could not open worker log $!";
        foreach my $file (qw(serial0.txt autoinst-log.txt serial_terminal.txt)) {
            next unless -e "$pooldir/$file";
            unlink("$pooldir/$file") or log_error "Could not unlink '$file': $!";
        }
    }
    my $name = $job_settings->{NAME};
    log_info(sprintf('got job %d: %s', $job->{id}, $name));

    # for the status call
    $log_offset             = 0;
    $serial_terminal_offset = 0;
    $current_running        = undef;
    $do_livelog             = 0;
    $has_developer_session  = 0;
    $tosend_images          = {};
    $tosend_files           = [];
    $current_host           = $host;
    ($ENV{OPENQA_HOSTNAME}) = $host =~ m|([^/]+:?\d*)/?$|;

    $worker = engine_workit($job);
    if ($worker->{error}) {
        log_warning('job is missing files, releasing job', channels => ['worker', 'autoinst'], default => 1);
        return stop_job("setup failure: $worker->{error}");
    }
    elsif ($worker->{child}->errored() || !$worker->{child}->is_running()) {
        log_warning('job errored. Releasing job', channels => ['worker', 'autoinst'], default => 1);
        return stop_job("job run failure");
    }
    my $isotovideo_pid = $worker->{child}->pid() // 'unknown';
    log_info("isotovideo has been started (PID: $isotovideo_pid)");

    my $jobid = $job->{id};

    # start updating status - slow updates if livelog is not running
    add_timer('update_status', STATUS_UPDATES_SLOW, \&update_status);
    # create job timeout timer
    add_timer(
        'job_timeout',
        $job_settings->{MAX_JOB_TIME} || $max_job_time,
        sub {
            # Prevent to determine status of job from exit_status
            eval {
                $worker->{child}->session->_protect(sub { $worker->{child}->unsubscribe('collected') })
                  if $worker->{child};
            };
            # abort job if it takes too long
            if ($job && $job->{id} eq $jobid) {
                log_warning("max job time exceeded, aborting $name");
                stop_job('timeout');
            }
        },
        1
    );
    OpenQA::Events->singleton->emit("start_job");
}

sub log_snippet {
    my ($file, $offset) = @_;

    my $fd;
    unless (open($fd, '<:raw', $file)) {
        return {};
    }
    my $ret = {offset => $$offset};

    sysseek($fd, $$offset, Fcntl::SEEK_SET);
    sysread($fd, my $buf = '', 100000);
    $ret->{data} = $buf;
    $$offset = sysseek($fd, 0, 1);
    close($fd);
    return $ret;
}

my $lastscreenshot = '';

# reads the base64 encoded content of a file below pooldir
sub read_base64_file($) {
    my ($file) = @_;
    my $c = path($pooldir, $file)->slurp;
    return encode_base64($c);
}

# reads the content of a file below pooldir and returns its md5
sub calculate_file_md5($) {
    my ($file) = @_;
    my $c   = path($pooldir, $file)->slurp;
    my $md5 = Digest::MD5->new;
    $md5->add($c);
    return $md5->clone->hexdigest;
}

sub read_last_screen {
    my $lastlink = readlink("$pooldir/qemuscreenshot/last.png");
    return if !$lastlink || $lastscreenshot eq $lastlink;
    my $png = read_base64_file("qemuscreenshot/$lastlink");
    $lastscreenshot = $lastlink;
    return {name => $lastscreenshot, png => $png};
}

# timer function ignoring arguments
sub update_status {
    return if $update_status_running;
    $update_status_running = 1;
    log_debug('updating status');
    upload_status();
    return;
}

sub stop_livelog {
    # We can have multiple viewers at the same time
    $do_livelog--;
    if ($do_livelog eq 0) {
        log_debug('Removing live_log mark, live views active');
        unlink "$pooldir/live_log";
    }
}

sub start_livelog {
    # We can have multiple viewers at the same time
    $do_livelog++;
    open my $fh, '>', "$pooldir/live_log" or die "Cannot create live_log file";
    close($fh);
}

sub has_logviewers {
    return $do_livelog // 0;
}

sub report_developer_session_started {
    $has_developer_session = 1;
    log_debug('Worker got notified that developer session has been started');
}

sub is_developer_session_started {
    return $has_developer_session;
}

# uploads current data
sub upload_status {
    my ($final_upload, $callback) = @_;

    # return if worker has setup failure
    return unless my $workerid = verify_workerid;
    return unless $job;
    if (!$job->{URL}) {
        return $callback->() if $callback && $final_upload;
        return;
    }

    # query status from isotovideo
    my $ua        = Mojo::UserAgent->new;
    my $os_status = $ua->get($job->{URL} . '/isotovideo/status')->res->json;
    my $status    = {
        worker_id             => $workerid,
        cmd_srv_url           => $job->{URL},
        worker_hostname       => $worker_settings->{WORKER_HOSTNAME},
        test_execution_paused => $os_status->{test_execution_paused},
    };

    # determine up to which module the results should be uploaded
    # note: $os_status->{running} is undef at the beginning or if read_json_file temporary
    #       failed and contains empty string after the last test
    my $upload_up_to;
    if ($os_status->{running} || $final_upload) {
        if (!$current_running) {    # first test
            $test_order = read_json_file('test_order.json');
            if (!$test_order) {
                stop_job('no tests scheduled');
                $update_status_running = 0;
                return $callback->() if $callback;
                return;
            }
            $status->{test_order} = $test_order;
            $status->{backend}    = $os_status->{backend};
        }
        elsif ($current_running ne ($os_status->{running} || '')) {    # new test
            $upload_up_to = $current_running;
        }
        $current_running = $os_status->{running};
    }

    # adjust $upload_up_to to handle special cases
    if ($final_upload) {
        # try to upload everything at the end, in case we missed the last $os_status->{running}
        $upload_up_to = '';
    }
    elsif ($status->{test_execution_paused}) {
        # upload up to the current module when paused so it is possible to open the needle editor
        $upload_up_to = $current_running;
    }

    # upload all results up to $upload_up_to
    if (defined($upload_up_to)) {
        $status->{result} = read_result_file($upload_up_to, $status->{test_order} //= []);
    }

    # provide status variables for livelog
    if (has_logviewers()) {
        $status->{log}             = log_snippet("$pooldir/autoinst-log.txt",   \$log_offset);
        $status->{serial_log}      = log_snippet("$pooldir/serial0",            \$serial_offset);
        $status->{serial_terminal} = log_snippet("$pooldir/virtio_console.log", \$serial_terminal_offset);
        my $screen = read_last_screen;
        $status->{screen} = $screen if $screen;
    }

    # mark the currently running test as running
    $status->{result}->{$current_running}->{result} = 'running' if ($current_running);

    # upload status to web UI
    my $job_id = $job->{id};
    ignore_known_images();
    if (is_developer_session_started()) {
        post_upload_progress_to_liveviewhandler($job_id, $upload_up_to);
    }
    api_call(
        'post',
        "jobs/$job_id/status",
        json     => {status => $status},
        callback => sub {
            handle_status_upload_finished($job_id, $upload_up_to, $callback, @_);
        });
    return 1;
}

sub handle_status_upload_finished {
    my ($job_id, $upload_up_to, $callback, $res) = @_;

    # stop if web UI considers this worker already dead
    if (!$res) {
        $update_status_running = 0;
        log_error('Job aborted because web UI doesn\'t accept updates anymore (likely considers this job dead)');
        stop_job('api-failure');
        return;
    }

    # continue uploading images
    $known_images = $res->{known_images};
    ignore_known_images();
    # stop if web UI considers this worker already dead
    if (!upload_images()) {
        $update_status_running = 0;
        log_error('Job aborted because web UI doesn\'t accept new images anymore (likely considers this job dead)');
        stop_job('api-failure');
        return;
    }

    if (is_developer_session_started()) {
        post_upload_progress_to_liveviewhandler($job_id, $upload_up_to);
    }

    $update_status_running = 0;
    return $callback->() if $callback;
    return;
}

sub post_upload_progress_to_liveviewhandler {
    my ($job_id, $upload_up_to) = @_;

    my %new_progress_info = (
        upload_up_to                => $upload_up_to,
        upload_up_to_current_module => $current_running && $upload_up_to && $current_running eq $upload_up_to,
        outstanding_files           => scalar(@$tosend_files),
        outstanding_images          => scalar(%$tosend_images),
    );

    # skip if the progress hasn't changed
    my $progress_changed;
    for my $key (qw(upload_up_to upload_up_to_current_module outstanding_files outstanding_images)) {
        my $new_value = $new_progress_info{$key};
        my $old_value = $progress_info->{$key};
        if (defined($new_value) != defined($old_value) || (defined($new_value) && $new_value ne $old_value)) {
            $progress_changed = 1;
            last;
        }
    }
    return unless $progress_changed;
    $progress_info = \%new_progress_info;

    api_call(
        post => "/liveviewhandler/api/v1/jobs/$job_id/upload_progress",
        service_port_delta => 2,                # liveviewhandler is supposed to run on web UI port + 2
        json               => $progress_info,
        non_critical       => 1,
        callback           => sub {
            my ($res) = @_;
            if (!$res) {
                log_error('Failed to post upload progress to liveviewhandler.');
                return;
            }
        });
}

sub optimize_image {
    my ($image) = @_;

    if (which('optipng')) {
        log_debug("optipng $image");
        # be careful not to be too eager optimizing, this needs to be quick
        # or we will be considered a dead worker
        system('optipng', '-quiet', '-o2', $image);
    }
    return;
}

sub ignore_known_images {
    for my $md5 (@$known_images) {
        delete $tosend_images->{$md5};
    }
}

sub upload_images {
    my $tx;
    my $ua_url = $hosts->{$current_host}{url}->clone;
    $ua_url->path("jobs/" . $job->{id} . "/artefact");

    my $fileprefix = "$pooldir/testresults";
    while (my ($md5, $file) = each %$tosend_images) {
        log_debug("upload $file as $md5");
        optimize_image("$fileprefix/$file");
        my $form = {
            file => {
                file     => "$fileprefix/$file",
                filename => $file
            },
            image => 1,
            thumb => 0,
            md5   => $md5
        };
        # don't use api_call as it retries and does not allow form data
        # (refactor at some point)
        $tx = $hosts->{$current_host}{ua}->post($ua_url => form => $form);

        $file = "$fileprefix/.thumbs/$file";
        if (-f $file) {
            optimize_image($file);
            $form->{file}->{file} = $file;
            $form->{thumb} = 1;
            $tx = $hosts->{$current_host}{ua}->post($ua_url => form => $form);
        }
    }
    $tosend_images = {};

    for my $file (@$tosend_files) {
        log_debug("upload $file");
        my $form = {
            file => {
                file     => "$pooldir/testresults/$file",
                filename => $file
            },
            image => 0,
            thumb => 0,
        };
        # don't use api_call as it retries and does not allow form data
        # (refactor at some point)
        $tx = $hosts->{$current_host}{ua}->post($ua_url => form => $form);
    }
    $tosend_files = [];
    return !$tx || !$tx->error;
}

sub read_json_file {
    my ($name) = @_;
    my $fn = "$pooldir/testresults/$name";
    local $/;
    my $fh;
    if (!open($fh, '<', $fn)) {
        warn "can't open $fn: $!";
        return;
    }
    my $json = {};
    eval { $json = decode_json(<$fh>); };
    warn "os-autoinst didn't write proper $fn" if $@;
    close($fh);
    return $json;
}

sub read_module_result {
    my ($test) = @_;

    my $result = read_json_file("result-$test.json");
    return unless $result;
    for my $d (@{$result->{details}}) {
        if ($d->{json}) {
            $d->{json} = $d->{json};
        }
        for my $n (@{$d->{needles}}) {
            $n->{json} = $n->{json};

        }
        for my $type (qw(screenshot audio text)) {
            my $file = $d->{$type};
            next unless $file;

            if ($type eq 'screenshot') {
                my $md5 = calculate_file_md5("testresults/$file");
                $d->{$type} = {
                    name => $file,
                    md5  => $md5,
                };
                $tosend_images->{$md5} = $file;
            }
            else {
                push @$tosend_files, $file;
            }
        }
    }
    return $result;
}

sub read_result_file {
    my ($upload_up_to, $extra_test_order) = @_;
    my $ret = {};

    # upload all results not yet uploaded - and stop at $upload_up_to
    # if $upload_up_to is empty string, then upload everything
    while (my $remaining_test_count = scalar(@$test_order)) {
        my $test   = $test_order->[0]->{name};
        my $result = read_module_result($test);

        my $is_last_test_to_be_uploaded = $remaining_test_count eq 1    || $test eq $upload_up_to;
        my $test_not_running            = !$current_running             || $test ne $current_running;
        my $test_is_completed           = !$is_last_test_to_be_uploaded || $test_not_running;
        if ($test_is_completed) {
            # remove completed tests from @$test_order so we don't upload those results twice
            shift(@$test_order);
        }

        last unless ($result);
        $ret->{$test} = $result;

        if ($result->{extra_test_results}) {
            for my $extra_test (@{$result->{extra_test_results}}) {
                my $extra_result = read_module_result($extra_test->{name});
                next unless $extra_result;
                $ret->{$extra_test->{name}} = $extra_result;
            }
            push @{$extra_test_order}, @{$result->{extra_test_results}};
        }

        last if $is_last_test_to_be_uploaded;
    }
    return $ret;
}

sub backend_running {
    # If we fail to cache assets, there is no $worker->{child}
    # and we did not created a process for it.
    !exists $worker->{child} ? !!0 : $worker->{child}->is_running;
}

1;
