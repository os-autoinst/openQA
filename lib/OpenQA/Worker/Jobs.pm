# Copyright (C) 2015,2016 SUSE LLC
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
use strict;
use warnings;
use feature 'state';

use OpenQA::Worker::Common;
use OpenQA::Worker::Pool qw/clean_pool/;
use OpenQA::Worker::Engines::isotovideo;

use POSIX qw/strftime SIGTERM/;
use File::Copy qw/copy move/;
use File::Path qw/remove_tree/;
use JSON qw/decode_json/;
use Fcntl;
use MIME::Base64;
use File::Basename qw/basename/;

use base qw/Exporter/;
our @EXPORT = qw/start_job stop_job check_job backend_running/;

my $worker;
my $log_offset   = 0;
my $max_job_time = 7200;    # 2h
my $current_running;
my $test_order;
my $stop_job_running;
my $update_status_running;

my $tosend_images = {};
my $tosend_files  = [];

our $do_livelog;

## Job management
sub _kill_worker($) {
    my ($worker) = @_;

    return unless $worker->{pid};

    warn "killing $worker->{pid}\n";
    kill(SIGTERM, $worker->{pid});

    # don't leave here before the worker is dead
    my $pid = waitpid($worker->{pid}, 0);
    if ($pid == -1) {
        warn "waitpid returned error: $!\n";
    }

    $worker = undef;
}

# method prototypes
sub start_job;

sub check_job {
    state $running;
    remove_timer('check_job');
    return if $running;
    return unless verify_workerid;
    $running = 1;
    if (!$job) {
        print "checking for job ...\n" if $verbose;
        my $res = api_call('post', "workers/$workerid/grab_job", $worker_caps) || {job => undef};
        $job = $res->{job};
        if ($job && $job->{id}) {
            Mojo::IOLoop->next_tick(\&start_job);
        }
        else {
            $job = undef;
        }
    }
    $running = 0;
}

sub _stop_job($;$);
sub stop_job($;$) {
    my ($aborted, $job_id) = @_;

    # we call this function in all situations, so better check
    return unless $job;
    return if $stop_job_running;
    return if $job_id && $job_id != $job->{id};
    $job_id = $job->{id};

    print "stop_job $aborted\n" if $verbose;
    $stop_job_running = 1;

    # stop all job related timers
    remove_timer('update_status');
    remove_timer('check_backend');
    remove_timer('job_timeout');

    # XXX: we need to wait if there is an update_status in progress.
    # we should have an event emitter that subscribes to update_status done
    my $stop_job_check_status;
    $stop_job_check_status = sub {
        if ($update_status_running) {
            print "waiting for update_status to finish\n" if $verbose;
            Mojo::IOLoop->timer(1 => $stop_job_check_status);
        }
        else {
            _stop_job($aborted, $job_id);
        }
    };

    $stop_job_check_status->();
}

sub upload {
    my ($job_id, $form) = @_;
    my $filename = $form->{file}->{filename};
    my $file     = $form->{file}->{file};

    # we need to open and close the log here as one of the files
    # might actually be autoinst-log.txt
    open(my $log, '>>', "autoinst-log.txt");
    printf $log "uploading %s\n", $filename;
    close $log;
    printf "uploading %s\n", $filename if $verbose;

    my $ua_url = $OpenQA::Worker::Common::url->clone;
    $ua_url->path("jobs/$job_id/artefact");

    my $tx = $OpenQA::Worker::Common::ua->build_tx(POST => $ua_url => form => $form);
    # override the default boundary calculation - it reads whole file
    # and it can cause various timeouts
    my $ct = $tx->req->headers->content_type;
    my $boundary = encode_base64 join('', map chr(rand 256), 1 .. 32);
    $boundary =~ s/\W/X/g;
    $tx->req->headers->content_type("$ct; boundary=$boundary");

    my $res = $OpenQA::Worker::Common::ua->start($tx);

    if (my $err = $res->error) {
        my $msg;
        if ($err->{code}) {
            $msg = sprintf "ERROR %s: $err->{code} response: $err->{message}\n", $filename;
        }
        else {
            $msg = sprintf "ERROR %s: Connection error: $err->{message}\n", $filename;
        }
        open(my $log, '>>', "autoinst-log.txt");
        print $log $msg;
        close $log;
        print STDERR $msg;
        return 0;
    }

    # double check uploads if the webui asks us to
    if ($res->res->json && $res->res->json->{temporary}) {
        my $csum1 = '1';
        my $size1;
        if (open(my $cfd, "-|", "cksum", $res->res->json->{temporary})) {
            ($csum1, $size1) = split(/ /, <$cfd>);
            close($cfd);
        }
        my $csum2 = '2';
        my $size2;
        if (open(my $cfd, "-|", "cksum", $file)) {
            ($csum2, $size2) = split(/ /, <$cfd>);
            close($cfd);
        }
        open(my $log, '>>', "autoinst-log.txt");
        print $log "Checksum $csum1:$csum2 Sizes:$size1:$size2\n";
        close $log;
        if ($csum1 eq $csum2 && $size1 eq $size2) {
            my $ua_url = $OpenQA::Worker::Common::url->clone;
            $ua_url->path("jobs/$job_id/ack_temporary");

            $OpenQA::Worker::Common::ua->post($ua_url => form => {temporary => $res->res->json->{temporary}});
        }
        else {
            return 0;
        }
    }
    return 1;
}

sub _stop_job($;$) {
    my ($aborted, $job_id) = @_;

    # now tell the webui that we're about to finish, but the following
    # process of killing the backend process and checksums uploads and
    # checksums again can take a long while, so the webui needs to know
    print "stop_job 2nd part\n" if $verbose;

    # the update_status timers and such are gone by now (1st part), so we're
    # basically "single threaded" and can block

    my $status = {state => 'uploading'};
    api_call('post', "jobs/$job_id/status", undef, {status => $status});

    _kill_worker($worker);

    print "stop_job 3rd part\n" if $verbose;

    my $name = $job->{settings}->{NAME};
    $aborted ||= 'done';

    my $job_done;    # undef

    open(my $log, '>>', "autoinst-log.txt");
    print $log "+++ worker notes +++\n";
    printf $log "end time: %s\n", strftime("%F %T", gmtime);
    print $log "result: $aborted\n";
    close $log;

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

        for my $file (qw(video.ogv vars.json serial0 autoinst-log.txt)) {
            next unless -e $file;
            # default serial output file called serial0
            my $ofile = $file;
            $ofile =~ s/serial0/serial0.txt/;
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
            printf "setting job %d to incomplete (obsolete)\n", $job->{id};
            upload_status(1);
            api_call('post', 'jobs/' . $job->{id} . '/set_done', {result => 'incomplete', newbuild => 1});
            $job_done = 1;
        }
        elsif ($aborted eq 'cancel') {
            # not using job_incomplete here to avoid duplicate
            printf "setting job %d to incomplete (cancel)\n", $job->{id};
            upload_status(1);
            api_call('post', 'jobs/' . $job->{id} . '/set_done', {result => 'incomplete'});
            $job_done = 1;
        }
        elsif ($aborted eq 'timeout') {
            printf "job %d spent more time than MAX_JOB_TIME\n", $job->{id};
        }
        elsif ($aborted eq 'done') {    # not aborted
            printf "setting job %d to done\n", $job->{id};
            upload_status(1);
            api_call('post', 'jobs/' . $job->{id} . '/set_done');
            $job_done = 1;
        }
    }
    unless ($job_done || $aborted eq 'api-failure') {
        upload_status(1);
        printf "job %d incomplete\n", $job->{id};
        api_call('post', 'jobs/' . $job->{id} . '/set_done', {result => 'incomplete'});
    }
    warn sprintf("cleaning up %s...\n", $job->{settings}->{NAME});
    clean_pool();
    $job              = undef;
    $worker           = undef;
    $stop_job_running = 0;

    if ($aborted eq 'quit') {
        Mojo::IOLoop->stop;
        return;
    }
    # immediatelly check for already scheduled job
    add_timer('check_job', 0, \&check_job, 1);
}

sub start_job {
    # block the job from having dangerous settings (isotovideo specific though)
    # it needs to come from worker_settings
    delete $job->{settings}->{GENERAL_HW_CMD_DIR};

    # update settings with worker-specific stuff
    @{$job->{settings}}{keys %$worker_settings} = values %$worker_settings;
    my $name = $job->{settings}->{NAME};
    printf "got job %d: %s\n", $job->{id}, $name;

    # for the status call
    $log_offset      = 0;
    $current_running = undef;
    $do_livelog      = 0;
    $tosend_images   = {};
    $tosend_files    = [];

    $worker = engine_workit($job);
    if ($worker->{error}) {
        warn "job is missing files, releasing job\n";
        return stop_job("setup failure: $worker->{error}");
    }

    # start updating status - slow updates if livelog is not running
    add_timer('update_status', STATUS_UPDATES_SLOW, \&update_status);
    # start backend checks
    add_timer('check_backend', 2, \&check_backend);
    # create job timeout timer
    add_timer(
        'job_timeout',
        $job->{settings}->{MAX_JOB_TIME} || $max_job_time,
        sub {
            # abort job if it takes too long
            if ($job) {
                warn sprintf("max job time exceeded, aborting %s ...\n", $name);
                stop_job('timeout');
            }
        },
        1
    );
}

sub log_snippet {
    my $file = "$pooldir/autoinst-log.txt";

    my $fd;
    unless (open($fd, '<:raw', $file)) {
        return {};
    }
    my $ret = {offset => $log_offset};

    sysseek($fd, $log_offset, Fcntl::SEEK_SET);
    sysread($fd, my $buf = '', 100000);
    $ret->{data} = $buf;
    $log_offset = sysseek($fd, 0, 1);
    close($fd);
    return $ret;
}

my $lastscreenshot = '';

# reads the base64 encoded content of a file below pooldir
sub read_base64_file($) {
    my ($file) = @_;
    my $c = OpenQA::Utils::file_content("$pooldir/$file");
    return encode_base64($c);
}

# reads the content of a file below pooldir and returns its md5
sub calculate_file_md5($) {
    my ($file) = @_;
    my $c      = OpenQA::Utils::file_content("$pooldir/$file");
    my $md5    = Digest::MD5->new;
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
    print "updating status\n" if $verbose;
    upload_status();
    $update_status_running = 0;
    return;
}

# uploads current data
sub upload_status(;$) {
    my ($final_upload) = @_;

    return unless verify_workerid;
    return unless $job;
    return unless $job->{URL};
    my $status = {};

    my $ua        = Mojo::UserAgent->new;
    my $os_status = $ua->get($job->{URL} . "/isotovideo/status")->res->json;

    # $os_status->{running} is undef at the beginning or if read_json_file temporary failed
    # and contains empty string after the last test

    # cherry-pick

    for my $f (qw/interactive needinput/) {
        if ($os_status->{$f} || $do_livelog) {
            $status->{status}->{$f} = $os_status->{$f};
        }
    }
    my $upload_up_to;

    if ($os_status->{running} || $final_upload) {
        if (!$current_running) {    # first test
            $test_order = read_json_file('test_order.json');
            if (!$test_order) {
                stop_job('no tests scheduled');
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
    if ($do_livelog) {
        $status->{log} = log_snippet;
        my $screen = read_last_screen;
        $status->{screen} = $screen if $screen;
    }

    # if there is nothing to say, don't say it (said my mother)
    return unless %$status;

    if ($os_status->{running}) {
        $status->{result}->{$os_status->{running}}->{result} = 'running';
    }

    if ($ENV{WORKER_USE_WEBSOCKETS}) {
        ws_call('status', $status);
    }
    else {
        my $res = api_call('post', 'jobs/' . $job->{id} . '/status', undef, {status => $status});
        upload_images($res->{known_images});
    }
}

sub upload_images {
    my ($known_images) = @_;

    for my $md5 (@$known_images) {
        delete $tosend_images->{$md5};
    }
    my $ua_url = $OpenQA::Worker::Common::url->clone;
    $ua_url->path("jobs/" . $job->{id} . "/artefact");

    while (my ($md5, $file) = each %$tosend_images) {
        print "upload $file as $md5\n" if ($verbose);

        my $form = {
            file => {
                file     => "$pooldir/testresults/$file",
                filename => $file
            },
            image => 1,
            thumb => 0,
            md5   => $md5
        };
        # don't use api_call as it retries and does not allow form data
        # (refactor at some point)
        $OpenQA::Worker::Common::ua->post($ua_url => form => $form);
        if (-f "$pooldir/testresults/.thumbs/$file") {
            $form->{file}->{file} = "$pooldir/testresults/.thumbs/$file";
            $form->{thumb} = 1;
            $OpenQA::Worker::Common::ua->post($ua_url => form => $form);
        }
    }
    $tosend_images = {};

    for my $file (@$tosend_files) {
        print "upload $file\n" if ($verbose);

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
        $OpenQA::Worker::Common::ua->post($ua_url => form => $form);
    }
    $tosend_files = [];
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
        for my $type (qw/screenshot audio text/) {
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
    return $worker;
}

sub check_backend {
    print "checking backend state ...\n" if $verbose;
    my $res = engine_check;
    if ($res && $res ne 'ok') {
        stop_job($res);
    }
}

1;
