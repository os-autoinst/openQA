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

package OpenQA::Worker::Engines::isotovideo;
use strict;
use warnings;

use OpenQA::Worker::Common;
use OpenQA::Utils qw(locate_asset log_error log_info log_debug);

use POSIX qw(:sys_wait_h strftime uname);
use JSON 'to_json';
use Fcntl;
use File::Spec::Functions 'catdir';
use File::Basename;
use Errno;
use Cwd 'abs_path';
use OpenQA::Cache;

my $isotovideo = "/usr/bin/isotovideo";
my $workerpid;

require Exporter;
our (@ISA, @EXPORT);
@ISA    = qw(Exporter);
@EXPORT = qw(engine_workit engine_check);

sub set_engine_exec {
    my ($path) = @_;
    die "Path to isotovideo invalid: $path" unless -f $path;
    # save the absolute path as we chdir later
    $isotovideo = abs_path($path);
}

sub _kill($) {
    my ($pid) = @_;
    if (kill('TERM', $pid)) {
        warn "killed $pid - waiting for exit";
        waitpid($pid, 0);
    }
}

sub _save_vars($) {
    my $vars = shift;
    die "cannot get environment variables!\n" unless $vars;
    my $fn = $pooldir . "/vars.json";
    unlink "$pooldir/vars.json" if -e "$pooldir/vars.json";
    open(my $fd, ">", $fn) or die "can not write vars.json: $!\n";
    fcntl($fd, F_SETLKW, pack('ssqql', F_WRLCK, 0, 0, 0, $$)) or die "cannot lock vars.json: $!\n";
    truncate($fd, 0) or die "cannot truncate vars.json: $!\n";

    print $fd to_json(\%$vars, {pretty => 1});
    close($fd);
}

sub cache_assets {
    my ($vars, $assetkeys) = @_;

    for my $this_asset (sort keys %$assetkeys) {
        log_debug("Found $this_asset, caching " . $vars->{$this_asset});
        my $asset = get_asset($job, $this_asset, $vars->{$this_asset});
        return {error => "Can't download $vars->{$this_asset}"} unless $asset;
        symlink($asset, basename($asset)) or die "cannot create link: $asset, $pooldir";
    }
    return undef;
}

sub cache_tests {

    my ($shared_cache, $testpoolserver) = @_;

    my $start = time;
    #Do an flock to ensure only one worker is trying to synchronize at a time.
    my @cmd = qw(flock -E 999);
    push @cmd, "$shared_cache/needleslock";
    push @cmd, (qw(rsync -avP), "$testpoolserver/", qw(--delete));
    push @cmd, "$shared_cache/tests/";

    log_debug("Calling " . join(' ', @cmd));
    my $res = system(@cmd);
    return {error => "Failed to rsync tests: '$@'"} if $res;
    log_debug(sprintf("RSYNC: Synchronization of tests directory took %.2f seconds", time - $start));
    return undef;
}

sub detect_asset_keys {
    my ($vars) = @_;

    my %res;
    for my $isokey (qw(ISO), map { "ISO_$_" } (1 .. 9)) {
        $res{$isokey} = 'iso' if $vars->{$isokey};
    }

    for my $otherkey (qw(KERNEL INITRD)) {
        $res{$otherkey} = 'other' if $vars->{$otherkey};
    }

    my $nd = $vars->{NUMDISKS} || 2;
    for my $i (1 .. $nd) {
        my $hddkey = "HDD_$i";
        $res{$hddkey} = 'hdd' if $vars->{$hddkey};
    }
    return \%res;
}

sub engine_workit {
    my ($job) = @_;

    if (open(my $log, '>', "autoinst-log.txt")) {
        print $log "+++ setup notes +++\n";
        printf $log "start time: %s\n", strftime("%F %T", gmtime);
        my ($sysname, $hostname, $release, $version, $machine) = POSIX::uname();
        printf $log "running on $hostname:%d ($sysname $release $version $machine)\n", $instance;
        close($log);
    }

    # set base dir to the one assigned with webui
    OpenQA::Utils::change_sharedir($hosts->{$current_host}{dir});

    # XXX: this should come from the worker table. Only included
    # here for convenience when looking at the pool of
    # debugging.
    for my $i (qw(QEMUPORT VNC OPENQA_HOSTNAME)) {
        $job->{settings}->{$i} = $ENV{$i};
    }
    if (open(my $fh, '>', 'job.json')) {
        print $fh to_json($job, {pretty => 1});
        close $fh;
    }

    # pass worker instance and worker id to isotovideo
    # both used to create unique MAC and TAP devices if needed
    # workerid is also used by libvirt backend to identify VMs
    my $openqa_url = $current_host;
    my $workerid   = $hosts->{$current_host}{workerid};
    my %vars       = (OPENQA_URL => $openqa_url, WORKER_INSTANCE => $instance, WORKER_ID => $workerid);
    while (my ($k, $v) = each %{$job->{settings}}) {
        log_debug("setting $k=$v") if $verbose;
        $vars{$k} = $v;
    }

    my $shared_cache;

    my $assetkeys = detect_asset_keys(\%vars);

    # for now the only condition to enable syncing is $hosts->{$current_host}{dir}
    if ($worker_settings->{CACHEDIRECTORY} && $hosts->{$current_host}{testpoolserver}) {
        my $host_to_cache = Mojo::URL->new($current_host)->host;
        $shared_cache = catdir($worker_settings->{CACHEDIRECTORY}, $host_to_cache);
        $vars{PRJDIR} = $shared_cache;
        OpenQA::Cache::init($current_host, $worker_settings->{CACHEDIRECTORY});
        my $error = cache_assets(\%vars, $assetkeys);
        return $error if $error;
        $error = cache_tests($shared_cache, $hosts->{$current_host}{testpoolserver});
        return $error if $error;
        $shared_cache = catdir($shared_cache, 'tests');
    }
    else {
        $vars{PRJDIR} = $OpenQA::Utils::sharedir;
        my $error = locate_local_assets(\%vars, $assetkeys);
        return $error if $error;
    }

    $vars{ASSETDIR}   = $OpenQA::Utils::assetdir;
    $vars{CASEDIR}    = OpenQA::Utils::testcasedir($vars{DISTRI}, $vars{VERSION}, $shared_cache);
    $vars{PRODUCTDIR} = OpenQA::Utils::productdir($vars{DISTRI}, $vars{VERSION}, $shared_cache);

    _save_vars(\%vars);

    # os-autoinst's commands server
    $job->{URL} = "http://localhost:" . ($job->{settings}->{QEMUPORT} + 1) . "/" . $job->{settings}->{JOBTOKEN};

    # create tmpdir for qemu to write here
    my $tmpdir = "$pooldir/tmp";
    mkdir($tmpdir) unless (-d $tmpdir);

    my $child = fork();
    die "failed to fork: $!\n" unless defined $child;

    unless ($child) {
        # create new process group
        setpgrp(0, 0);
        $ENV{TMPDIR} = $tmpdir;
        log_info("$$: WORKING " . $job->{id});
        if (open(my $log, '>>', "autoinst-log.txt")) {
            print $log "+++ worker notes +++\n";
            printf $log "start time: %s\n", strftime("%F %T", gmtime);
            my ($sysname, $hostname, $release, $version, $machine) = POSIX::uname();
            printf $log "running on $hostname:%d ($sysname $release $version $machine)\n", $instance;
            close($log);
        }
        open STDOUT, ">>", "autoinst-log.txt";
        open STDERR, ">&STDOUT";
        exec "perl", "$isotovideo", '-d';
        die "exec failed: $!\n";
    }
    else {
        $workerpid = $child;
        return {pid => $child};
    }

}

sub locate_local_assets {
    my ($vars, $assetkeys) = @_;

    for my $key (keys %$assetkeys) {
        my $file = locate_asset($assetkeys->{$key}, $vars->{$key}, mustexist => 1);
        unless ($file) {
            my $error = "Cannot find $key asset $assetkeys->{$key}/$vars->{$key}!";
            return {error => $error};
        }
        $vars->{$key} = $file;
    }
    return undef;
}

sub engine_check {
    # abort job if backend crashed and reschedule it
    if (-e "$pooldir/backend.crashed") {
        unlink("$pooldir/backend.crashed");
        log_error('backend crashed ...');
        if (open(my $fh, '<', "$pooldir/os-autoinst.pid")) {
            local $/;
            my $pid = <$fh>;
            close $fh;
            if ($pid =~ /(\d+)/) {
                log_info("killing os-autoinst $1");
                _kill($1);
            }
        }
        if (open(my $fh, '<', "$pooldir/qemu.pid")) {
            local $/;
            my $pid = <$fh>;
            close $fh;
            if ($pid =~ /(\d+)/) {
                log_info("killing qemu $1");
                _kill($1);
            }
        }
        return 'crashed';
    }

    # check if the worker is still running
    my $pid = waitpid($workerpid, WNOHANG);
    if ($verbose) {
        log_debug("waitpid $workerpid returned $pid with status $?");
    }
    if ($pid == -1 && $!{ECHILD}) {
        warn "we lost our child\n";
        return 'died';
    }

    if ($pid == $workerpid) {
        if ($?) {
            warn "child $pid died with exit status $?\n";
            return 'died';
        }
        else {
            return 'done';
        }
    }
    return;
}
