# Copyright (C) 2015 SUSE Linux Products GmbH
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
my $log_offset = 0;
my $max_job_time = 7200; # 2h
my $current_running;
my $test_order;
my $stop_job_running;
my $update_status_running;

my $tosend_images = {};

our $do_livelog;

## Job management
sub _kill_worker($) {
    my ($worker) = @_;

    return unless $worker;

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
        my $res = api_call('post',"workers/$workerid/grab_job", $worker_caps) || { job => undef };
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
    return if $job_id && $job_id != $job->{'id'};
    $job_id = $job->{'id'};

    print "stop_job $aborted\n" if $verbose;
    $stop_job_running = 1;

    # stop all job related timers
    remove_timer('update_status');
    remove_timer('check_backend');
    remove_timer('job_timeout');

    _kill_worker($worker);

    # XXX: we need to wait if there is an update_status in progress.
    # we should have an event emitter that subscribes to update_status done
    my $stop_job_check_status;
    $stop_job_check_status = sub {
        if($update_status_running) {
            print "waiting for update_status to finish\n" if $verbose;
            Mojo::IOLoop->timer(1 => $stop_job_check_status);
        }
        else {
            _stop_job($aborted, $job_id);
        }
    };

    $stop_job_check_status->();
}

sub _stop_job($;$) {
    my ($aborted, $job_id) = @_;

    print "stop_job 2nd half\n" if $verbose;

    my $name = $job->{'settings'}->{'NAME'};
    $aborted ||= 'done';

    my $job_done; # undef

    if ($aborted ne 'quit' && $aborted ne 'abort' && $aborted ne 'api-failure') {
        # collect uploaded logs
        my $ua_url = $OpenQA::Worker::Common::url->clone;
        $ua_url->path("jobs/$job_id/artefact");

        my @uploaded_logfiles = <$pooldir/ulogs/*>;
        for my $file (@uploaded_logfiles) {
            next unless -f $file;

            # don't use api_call as it retries and does not allow form data
            # (refactor at some point)
            my $res = $OpenQA::Worker::Common::ua->post(
                $ua_url => form => {
                    file => { file => $file, filename => basename($file) },
                    ulog => 1
                }
            );
        }
        if (open(my $log, '>>', "autoinst-log.txt")) {
            print $log "+++ worker notes +++\n";
            printf $log "end time: %s\n", strftime("%F %T", gmtime);
            print $log "result: $aborted\n";
            close $log;
        }
        for my $file (qw(video.ogv autoinst-log.txt vars.json serial0)) {
            # default serial output file called serial0
            my $ofile = $file;
            $ofile =~ s/serial0/serial0.txt/;
            my $res = $OpenQA::Worker::Common::ua->post(
                $ua_url => form => {
                    file => { file => "$pooldir/$file", filename => $ofile }
                }
            );
        }

        if ($aborted eq 'obsolete') {
            printf "setting job %d to incomplete (obsolete)\n", $job->{'id'};
            upload_status(1);
            api_call('post', 'jobs/'.$job->{'id'}.'/set_done', {result => 'incomplete', newbuild => 1});
            $job_done = 1;
        }
        elsif ($aborted eq 'cancel') {
            # not using job_incomplete here to avoid duplicate
            printf "setting job %d to incomplete (cancel)\n", $job->{'id'};
            upload_status(1);
            api_call('post', 'jobs/'.$job->{'id'}.'/set_done', {result => 'incomplete'});
            $job_done = 1;
        }
        elsif ($aborted eq 'timeout') {
            printf "job %d spent more time than MAX_JOB_TIME\n", $job->{'id'};
        }
        elsif ($aborted eq 'done') { # not aborted
            printf "setting job %d to done\n", $job->{'id'};
            upload_status(1);
            api_call('post', 'jobs/'.$job->{'id'}.'/set_done');
            $job_done = 1;
        }
    }
    unless ($job_done) {
        # set job to done. if priority is less than threshold duplicate it
        # with worse priority so it can be picked up again.
        my %args;
        $args{dup_type_auto} = 1;
        printf "duplicating job %d\n", $job->{'id'};
        # make it less attractive so we don't get it again
        api_call('post', 'jobs/'.$job->{'id'}.'/duplicate', \%args);
        api_call('post', 'jobs/'.$job->{'id'}.'/set_done', {result => 'incomplete'});
    }
    warn sprintf("cleaning up %s...\n", $job->{'settings'}->{'NAME'});
    clean_pool();
    $job = undef;
    $worker = undef;
    $stop_job_running = 0;

    if ($aborted eq 'quit') {
        Mojo::IOLoop->stop;
        return;
    }
    # immediatelly check for already scheduled job
    add_timer('check_job', 0, \&check_job, 1) unless ($job);
}

sub start_job {
    # update settings with worker-specific stuff
    @{$job->{'settings'}}{keys %$worker_settings} = values %$worker_settings;
    my $name = $job->{'settings'}->{'NAME'};
    printf "got job %d: %s\n", $job->{'id'}, $name;

    # for the status call
    $log_offset = 0;
    $current_running = undef;
    $do_livelog = 0;
    $tosend_images = {};

    $worker = engine_workit($job);
    unless ($worker) {
        warn "job is missing files, releasing job\n";
        return stop_job('setup failure');
    }

    # start updating status - slow updates if livelog is not running
    add_timer('update_status', STATUS_UPDATES_SLOW, \&update_status);
    # start backend checks
    add_timer('check_backend', 2, \&check_backend);
    # create job timeout timer
    add_timer(
        'job_timeout',
        $job->{'settings'}->{'MAX_JOB_TIME'} || $max_job_time,
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
    my $c = OpenQA::Utils::file_content("$pooldir/$file");
    my $md5 = Digest::MD5->new;
    $md5->add($c);
    return $md5->clone->hexdigest;
}

sub read_last_screen {
    my $lastlink = readlink("$pooldir/qemuscreenshot/last.png");
    return undef if !$lastlink || $lastscreenshot eq $lastlink;
    my $png = read_base64_file("qemuscreenshot/$lastlink");
    $lastscreenshot = $lastlink;
    return { name => $lastscreenshot, png => $png };
}

# timer function ignoring arguments
sub update_status {
    return if $update_status_running;
    $update_status_running = 1;
    upload_status();
    $update_status_running = 0;
    return;
}

# uploads current data
sub upload_status(;$) {
    my ($upload_running) = @_;

    return unless verify_workerid;
    return unless $job;
    my $status = {};

    my $os_status = read_json_file('status.json') || {};
    # cherry-pick

    for my $f (qw/interactive needinput/) {
        if ($os_status->{$f} || $do_livelog) {
            $status->{status} //= {};
            $status->{status}->{$f} = $os_status->{$f};
        }
    }
    my $upload_result;
    $upload_result = $current_running if ($upload_running);

    if ($os_status->{running} || $upload_running) {
        if (!$current_running) { # first test
            $test_order = read_json_file('test_order.json');
            if (!$test_order ) {
                stop_job('no tests scheduled');
                return;
            }
            $status->{test_order} = $test_order;
            $status->{backend}    = $os_status->{backend};
        }
        elsif ($current_running ne $os_status->{running}) { # new test
            $upload_result = $current_running;
        }
        $current_running = $os_status->{running};
    }
    if ($upload_result) {
        $status->{result} = read_result_file($upload_result);
        if ($os_status->{running}) {
            $status->{result}->{$os_status->{running}} //= {};
            $status->{result}->{$os_status->{running}}->{result} = 'running';
        }
    }
    if ($do_livelog) {
        $status->{'log'} = log_snippet;
        my $screen = read_last_screen;
        $status->{'screen'} = $screen if $screen;
    }

    # if there is nothing to say, don't say it (said my mother)
    return unless %$status;

    my $res = api_call('post', 'jobs/'.$job->{id}.'/status', undef, {status => $status});

    for my $md5 (@{$res->{known_images}}) {
        delete $tosend_images->{$md5};
    }
    my $ua_url = $OpenQA::Worker::Common::url->clone;
    $ua_url->path("jobs/" . $job->{id} . "/artefact");

    while (my ($md5, $file) = each %$tosend_images) {
        print "upload $file as $md5\n" if ($verbose);

        my $form = {
            file => {
                file => "$pooldir/testresults/$file",
                filename => $md5
            },
            image => 1,
            thumb => 0,
            md5 => $md5
        };
        # don't use api_call as it retries and does not allow form data
        # (refactor at some point)
        $OpenQA::Worker::Common::ua->post($ua_url => form => $form);
        $form->{file}->{file} = "$pooldir/testresults/.thumbs/$file";
        $form->{thumb} = 1;
        $OpenQA::Worker::Common::ua->post($ua_url => form => $form);
    }
    $tosend_images = {};
}

sub read_json_file {
    my ($name) = @_;
    my $fn = "$pooldir/testresults/$name";
    local $/;
    my $fh;
    if (!open($fh, '<', $fn)) {
        warn "can't open $fn: $!";
        return undef;
    }
    my $json = {};
    eval {$json = decode_json(<$fh>);};
    warn "os-autoinst didn't write proper $fn" if $@;
    close($fh);
    return $json;
}

sub read_result_file($) {
    my ($name) = @_;

    my $ret = {};

    # we need to upload all results not yet uploaded - and stop at $name
    while (scalar(@$test_order)) {
        my $test = (shift @$test_order)->{name};
        my $result = read_json_file("result-$test.json");
        last unless $result;
        for my $d (@{$result->{details}}) {
            my $screen = $d->{screenshot};
            next unless $screen;
            my $md5 = calculate_file_md5("testresults/$screen");
            $d->{screenshot} ={
                name => $screen,
                md5 => $md5,
            };
            $tosend_images->{$md5} = $screen;
        }
        $ret->{$test} = $result;

        last if ($test eq $name);
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
