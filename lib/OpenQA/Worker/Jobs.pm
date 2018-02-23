# Copyright (C) 2015-2017 SUSE LLC
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
use Cpanel::JSON::XS 'decode_json';
use Fcntl;
use MIME::Base64;
use File::Basename 'basename';
use File::Which 'which';
use Mojo::File 'path';
use Mojo::IOLoop;
use OpenQA::File;
use Mojo::IOLoop::ReadWriteProcess;

use POSIX ':sys_wait_h';

use base 'Exporter';
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

my $tosend_images = {};
my $tosend_files  = [];

our $do_livelog;

## Job management
sub _kill_worker($) {
    my ($worker) = @_;
    return if !$worker->{child} || !$worker->{child}->is_running;
    $worker->{child}->stop;
}

# method prototypes
sub start_job;

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
    my ($aborted, $job_id) = @_;
    # we call this function in all situations, so better check
    if (!$job || $stop_job_running) {
        # In case there is no job, or if the job was asked to stop
        # we stop the worker asap, otherwise wait for the actual
        # stop to finish before, or run into a condition where the job
        # runs forever and worker Mojo::IOLoop->stop is never called
        my $job_state = ($stop_job_running) ? "$stop_job_running" : 'No job was asked to stop|';
        $job_state .= ($aborted) ? "|Reason: $aborted" : ' $aborted is empty';
        log_debug("Either there is no job running or we were asked to stop: ($job_state)");
        Mojo::IOLoop->stop if $aborted eq 'quit';
        return;
    }
    return if $job_id && $job_id != $job->{id};

    $job_id = $job->{id};

    log_debug("stop_job $aborted");
    $stop_job_running = 1;

    # stop all job related timers
    remove_timer('update_status');
    remove_timer('job_timeout');

    # XXX: we need to wait if there is an update_status in progress.
    # we should have an event emitter that subscribes to update_status done
    my $stop_job_check_status;
    $stop_job_check_status = sub {
        if ($update_status_running) {
            log_debug("waiting for update_status to finish");
            Mojo::IOLoop->timer(1 => $stop_job_check_status);
        }
        else {
            _stop_job($aborted, $job_id);
        }
    };

    $stop_job_check_status->();
}

sub verify_job {
    return 1 if $job && ref($job) eq "HASH";
    return 0;
}

sub _reset_state {
    log_info('cleaning up ' . $job->{settings}->{NAME}) if verify_job && exists $job->{settings}->{NAME};
    clean_pool;
    $job              = undef;
    $worker           = undef;
    $stop_job_running = 0;
    $current_host     = undef;
    Mojo::IOLoop->singleton->emit("stop_job");
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
                "Upload failed for chunk " . $chunk->index . ": " . $e->body,
                channels => ['autoinst', 'worker'],
                default  => 1
            );
        });

    $client->upload->once(
        'upload_chunk.error' => sub {
            $e = pop();
            log_error($e->body, channels => ['autoinst', 'worker'], default => 1);
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

    $client->upload->unsubscribe('upload_chunk.response');
    $client->upload->unsubscribe('upload_chunk.start');
    $client->upload->unsubscribe('upload_chunk.finish');
    $client->upload->unsubscribe('upload_chunk.prepare');
    $client->upload->unsubscribe('upload_chunk.error');
    $client->upload->unsubscribe('upload_chunk.fail');

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

sub _stop_job {
    my ($aborted, $job_id) = @_;
    my $workerid = verify_workerid;

    # now tell the webui that we're about to finish, but the following
    # process of killing the backend process and checksums uploads and
    # checksums again can take a long while, so the webui needs to know

    if ($aborted eq "scheduler_abort") {
        log_debug('stop_job called by the scheduler. do not send logs');
        _kill_worker($worker);
        _reset_state;
        return;
    }

    # the update_status timers and such are gone by now (1st part), so we're
    # basically "single threaded" and can block

    my $status = {uploading => 1, worker_id => $workerid};
    api_call(
        'post', "jobs/$job_id/status",
        json => {status => $status},
        callback => sub { _stop_job_2($aborted, $job_id); });
}

sub _stop_job_2 {
    my ($aborted, $job_id) = @_;
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

        if ($aborted eq 'done') {
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
        for my $file (qw(video.ogv vars.json serial0 autoinst-log.txt virtio_console.log worker-log.txt)) {
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
    unless ($job_done || $aborted eq 'api-failure') {
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
        _reset_state;
    }
}

sub _stop_job_finish {
    my ($params, $quit) = @_;
    log_debug("update status running $update_status_running")
      if $update_status_running;
    if ($update_status_running) {
        add_timer('', 1, sub { _stop_job_finish($params, $quit) }, 1);
        return;
    }
    api_call(
        'post',
        'jobs/' . $job->{id} . '/set_done',
        params   => $params,
        callback => sub {
            _reset_state;
            if ($quit) {
                Mojo::IOLoop->stop;
            }
            #  else {
            # immediatelly check for already scheduled job
            #Mojo::IOLoop->next_tick(sub { check_job(keys %$hosts) });
            #  }
        });
}

sub copy_job_settings {
    my ($j, $worker_settings) = @_;
    my @worker_settings_key = keys %$worker_settings;
    @{$j->{settings}}{@worker_settings_key} = @{$worker_settings}{@worker_settings_key};
}

sub start_job {
    my ($host) = @_;

    return _reset_state unless verify_job;
    # block the job from having dangerous settings (isotovideo specific though)
    # it needs to come from worker_settings
    delete $job->{settings}->{GENERAL_HW_CMD_DIR};
    # add_log_channel('worker', path => 'worker-log.txt', level => $worker_settings->{LOG_LEVEL} // 'info');

    # update settings with worker-specific stuff
    copy_job_settings($job, $worker_settings);

    my $name = $job->{settings}->{NAME};
    log_info(sprintf('got job %d: %s', $job->{id}, $name));

    # for the status call
    $log_offset             = 0;
    $serial_terminal_offset = 0;
    $current_running        = undef;
    $do_livelog             = 0;
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

    my $jobid = $job->{id};

    # start updating status - slow updates if livelog is not running
    add_timer('update_status', STATUS_UPDATES_SLOW, \&update_status);
    # create job timeout timer
    add_timer(
        'job_timeout',
        $job->{settings}->{MAX_JOB_TIME} || $max_job_time,
        sub {
            # Prevent to determine status of job from exit_status
            eval { $worker->{child}->unsubscribe('collected') if $worker->{child}; };
            # abort job if it takes too long
            if ($job && $job->{id} eq $jobid) {
                log_warning("max job time exceeded, aborting $name");
                stop_job('timeout');
            }
        },
        1
    );
    Mojo::IOLoop->singleton->emit("start_job");
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
    my $c = path($pooldir, $file)->slurp;
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

# uploads current data
sub upload_status {
    my ($final_upload, $callback) = @_;


    return unless my $workerid = verify_workerid;
    return unless $job;

    # If the worker has a setup failure, the $job object is not
    # properly set, and URL is not set, so we return.
    if (!$job->{URL}) {
        return $callback->() if $callback && $final_upload;
        return;
    }

    my $status = {worker_id => $workerid};

    my $ua        = Mojo::UserAgent->new;
    my $os_status = $ua->get($job->{URL} . "/isotovideo/status")->res->json;

    # $os_status->{running} is undef at the beginning or if read_json_file temporary failed
    # and contains empty string after the last test

    # cherry-pick

    for my $f (qw(interactive needinput)) {
        if ($os_status->{$f} || has_logviewers()) {
            $status->{status}->{$f} = $os_status->{$f};
        }
    }
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

    # try to upload everything at the end, in case we missed the last $os_status->{running}
    $upload_up_to = '' if $final_upload;

    if ($status->{status}->{needinput}) {
        $status->{result} = {$current_running => read_module_result($os_status->{running})};
    }
    elsif (defined($upload_up_to)) {
        my $extra_test_order = [];
        $status->{result} = read_result_file($upload_up_to, $extra_test_order);

        if (@$extra_test_order) {
            $status->{test_order} //= [];
            push @{$status->{test_order}}, @$extra_test_order;
        }
    }
    if (has_logviewers()) {
        $status->{log}             = log_snippet("$pooldir/autoinst-log.txt",   \$log_offset);
        $status->{serial_log}      = log_snippet("$pooldir/serial0",            \$serial_offset);
        $status->{serial_terminal} = log_snippet("$pooldir/virtio_console.log", \$serial_terminal_offset);
        my $screen = read_last_screen;
        $status->{screen} = $screen if $screen;
    }

    # if there is nothing to say, don't say it (said my mother)
    unless (%$status) {
        $update_status_running = 0;
        return $callback->() if $callback;
        return;
    }

    if ($os_status->{running}) {
        $status->{result}->{$os_status->{running}}->{result} = 'running';
    }

    if ($ENV{WORKER_USE_WEBSOCKETS}) {
        ws_call('status', $status);
    }
    else {
        api_call(
            'post',
            'jobs/' . $job->{id} . '/status',
            json     => {status => $status},
            callback => sub {
                my ($res) = @_;
                if (!$res) {
                    # web UI considers this worker already dead anyways, so just exit here
                    log_error(
                        'Job aborted because web UI doesn\'t accept updates anymore (likely considers this job dead)');
                }
                elsif (!upload_images($res->{known_images})) {
                    log_error(
                        'Job aborted because web UI doesn\'t accept new images anymore (likely considers this job dead)'
                    );
                }
                $update_status_running = 0;
                return $callback->() if $callback;
                return;
            });
    }
    return 1;
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

sub upload_images {
    my ($known_images) = @_;

    for my $md5 (@$known_images) {
        delete $tosend_images->{$md5};
    }
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
    return !$tx || $tx->success;
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

sub read_module_result($) {
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

sub read_result_file($$) {
    my ($upload_up_to, $extra_test_order) = @_;

    my $ret = {};

    # we need to upload all results not yet uploaded - and stop at $upload_up_to
    # if $upload_up_to is empty string, then upload everything
    while (scalar(@$test_order)) {
        my $test   = (shift @$test_order)->{name};
        my $result = read_module_result($test);
        last unless $result;
        $ret->{$test} = $result;

        if ($result->{extra_test_results}) {

            for my $extra_test (@{$result->{extra_test_results}}) {
                my $extra_result = read_module_result($extra_test->{name});
                next unless $extra_result;
                $ret->{$extra_test->{name}} = $extra_result;
            }
            push @{$extra_test_order}, @{$result->{extra_test_results}};
        }

        last if ($test eq $upload_up_to);
    }
    return $ret;
}

sub backend_running {
    return $worker->{child}->is_running;
}

1;
