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

use OpenQA::Worker::Common;
use OpenQA::Worker::Pool qw/clean_pool/;
use OpenQA::Worker::Engines::isotovideo;

use POSIX qw/strftime SIGTERM/;
use File::Copy qw/copy move/;
use File::Path qw/remove_tree/;
use JSON qw/decode_json/;
use Fcntl;

use base qw/Exporter/;
our @EXPORT = qw/start_job stop_job check_job backend_running/;

my $worker;
my $log_offset = 0;
my $max_job_time = 7200; # 2h
my $current_running;

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
    return unless verify_workerid;
    if (!$job) {
        print "checking for job ...\n" if $verbose;
        my $res = api_call('post',"workers/$workerid/grab_job", $worker_caps) || { job => undef };
        $job = $res->{job};
        if ($job && $job->{id}) {
            # stop job check
            remove_timer('check_job');
            return start_job;
        }
        $job = undef;
    }
}

sub stop_job($;$) {
    my ($aborted, $job_id) = @_;

    # we call this function in all situations, so better check
    return unless $job;
    return if $job_id && $job_id != $job->{'id'};

    print "stop_job $aborted\n" if $verbose;

    # stop all job related timers
    remove_timer('update_status');
    remove_timer('check_backend');
    remove_timer('job_timeout');

    _kill_worker($worker);

    my $name = $job->{'settings'}->{'NAME'};
    $aborted ||= 'done';

    if (open(my $log, '>>', RESULTS_DIR . '/runlog.txt')) {
        if (fcntl($log, F_SETLKW, pack('ssqql', F_WRLCK, 0, 0, 0, $$))) {
            printf $log "%s finished to create %s: %s\n",strftime("%F %T", gmtime),$name, $aborted;
        }
        close($log);
    }

    my $job_done; # undef

    if ($aborted ne 'quit' && $aborted ne 'abort') {
        # collect uploaded logs
      my @uploaded_logfiles = <$pooldir/ulogs/*>;
      print STDERR "TODO: upload logs!\n";
#        mkdir("$pooldir/testresults/ulogs/");
#        for my $uploaded_logfile (@uploaded_logfiles) {
#            next unless -f $uploaded_logfile;
#            unless(copy($uploaded_logfile, "$testresults/ulogs/")) {
#                warn "can't copy ulog: $uploaded_logfile -> $testresults/ulogs/\n";
#            }
#        }
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
            unless (move("$pooldir/$file", join('/', $testresults, $ofile))) {
                warn "can't move $file: $!\n";
            }
        }

        if ($aborted eq 'obsolete') {
            printf "setting job %d to incomplete (obsolete)\n", $job->{'id'};
            api_call('post', 'jobs/'.$job->{'id'}.'/set_done', {result => 'incomplete', newbuild => 1});
            $job_done = 1;
        }
        elsif ($aborted eq 'cancel') {
            # not using job_incomplete here to avoid duplicate
            printf "setting job %d to incomplete (cancel)\n", $job->{'id'};
            api_call('post', 'jobs/'.$job->{'id'}.'/set_done', {result => 'incomplete'});
            $job_done = 1;
        }
        elsif ($aborted eq 'timeout') {
            printf "job %d spent more time than MAX_JOB_TIME\n", $job->{'id'};
        }
        elsif ($aborted eq 'done') { # not aborted
            printf "setting job %d to done\n", $job->{'id'};
            api_call('post', 'jobs/'.$job->{'id'}.'/set_done');
            $job_done = 1;
        }
    }
    unless ($job_done) {
        job_incomplete($job);
    }
    warn sprintf("cleaning up %s...\n", $job->{'settings'}->{'NAME'});
    clean_pool();
    $job = undef;
    $worker = undef;

    return if ($aborted eq 'quit');
    # immediatelly check for already scheduled job
    check_job();
    # and start backup checking for job if none was acquired
    add_timer('check_job', 10, \&check_job) unless ($job);
}

sub start_job {
    # update settings with worker-specific stuff
  @{$job->{'settings'}}{keys %$worker_settings} = values %$worker_settings;
  my $name = $job->{'settings'}->{'NAME'};
    printf "got job %d: %s\n", $job->{'id'}, $name;
    $max_job_time = $job->{'settings'}->{'MAX_JOB_TIME'} || 2*60*60; # 2h

    # for the status call
    $log_offset = 0;
  $current_running = undef;
  
    $worker = engine_workit($job);
    unless ($worker) {
        warn "job is missing files, releasing job\n";
        return stop_job('setup failure');
    }
    if ($job && open(my $log, '>>', RESULTS_DIR . '/runlog.txt')) {
        if (fcntl($log, F_SETLKW, pack('ssqql', F_WRLCK, 0, 0, 0, $$))) {
            my @s = map { sprintf("%s=%s", $_, $job->{'settings'}->{$_}) } grep { $_ ne 'ISO' && $_ ne 'NAME' } keys %{$job->{'settings'}};
            printf $log "%s started to create %s %s\n",strftime("%F %T", gmtime), $name, join(' ', @s);
        }
        close($log);
    }
    # start updating status - slow updates if livelog is not running
    add_timer('update_status', STATUS_UPDATES_SLOW, \&update_status);
    # start backend checks
    add_timer('check_backend', 2, \&check_backend);
    # create job timeout timer
    add_timer(
        'job_timeout',
        $max_job_time,
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

# uploads current data
sub update_status {
    return unless verify_workerid;
    return unless $job;
    my $status = {};

    #$status->{'log'} = log_snippet;
    my $os_status = read_json_file('status.json');
    $status->{'status'} = $os_status;
    if ($os_status->{'running'}) {
      if (!$current_running) { # first test
	$status->{'test_order'} = read_json_file('test_order.json');

      } elsif ($current_running ne $os_status->{'running'}) { # new test
	$status->{'result'} = { $current_running => read_json_file("result-$current_running.json") };
      }
      $current_running = $os_status->{'running'};
    }
    use Data::Dumper;
    print STDERR Dumper($status);
    api_call('post', 'jobs/'.$job->{id}.'/status', undef, {status => $status});
}

# set job to done. if priority is less than threshold duplicate it
# with worse priority so it can be picked up again.
sub job_incomplete($){
    my ($job) = @_;
    my %args;
    $args{dup_type_auto} = 1;

    printf "duplicating job %d\n", $job->{'id'};
    # make it less attractive so we don't get it again
    api_call('post', 'jobs/'.$job->{'id'}.'/duplicate', \%args);

    # set result after creating duplicate job so the chained jobs can survive
    api_call('post', 'jobs/'.$job->{'id'}.'/set_done', {result => 'incomplete'});

    clean_pool();
}

# check if results.json contains an overal result. If the latter is
# missing the worker probably crashed.
sub read_json_file {
  my ($name) = @_;
    my $fn = "$pooldir/testresults/$name";
    my $ret;
    local $/;
    open(my $fh, '<', $fn) or return 0;
    my $json = {};
    eval {$json = decode_json(<$fh>);};
    warn "os-autoinst didn't write proper $fn" if $@;
    close($fh);
    return $json;
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
