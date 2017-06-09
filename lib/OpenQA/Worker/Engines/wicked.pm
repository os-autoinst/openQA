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

package OpenQA::Worker::Engines::wicked;
use strict;
use warnings;



#export epoch_date=$(date +%s)
#export DISTRI="${DISTRI:-"sle"}"
#export VERSION="${VERSION:-"12-SP3"}"
#export ARCH="${ARCH:-"x86_64"}"
#export FLAVOR="${FLAVOR:-"Server-DVD"}"
#export MACHINE="${MACHINE:-"64bit"}"
#export WORKER_CLASS="${WORKER_CLASS:-"zzzz_for_wicked"}"
#export _GROUP="${_GROUP:-"Network"}"
#export BUILD="${BUILD:-${epoch_date}}"



#export BUILD_NAME="${BUILD_NAME:-"wicked_master_nanny"}"
#export BUILD_NUMBER="${BUILD_NUMBER:-"1"}"
#export COMPILE_WICKED="${COMPILE_WICKED:-"false"}"
#export IMAGE_NAME_SUT="${IMAGE_NAME_SUT:-"SLE_12_SP3_Build0314-x86_64-default"}"
#export WORKSPACE="${WORKSPACE:-"/var/lib/jenkins/workspace/wicked_master_nanny"}"


#[DEBUG] setting NAME=00000012-sle-12-SP3-Server-DVD-x86_64-Build0420-installcheck@64bit
#[DEBUG] setting BUILD_WE=0139
#[DEBUG] setting QA_WEB_REPO=http://dist.suse.de/install/SLP/SLE-12-Module-Web-Scripting-LATEST/x86_64/CD1/
#[DEBUG] setting HDDSIZEGB=20
#[DEBUG] setting VIRTIO_CONSOLE=1
#[DEBUG] setting BUILD_SLE=0420
#[DEBUG] setting MACHINE=64bit
#[DEBUG] setting ISO_MAXSIZE=4700372992
#[DEBUG] setting FLAVOR=Server-DVD
#[DEBUG] setting TEST=installcheck
#[DEBUG] setting ISO=SLE-12-SP3-Server-DVD-x86_64-Build0420-Media1.iso
#[DEBUG] setting DISTRI=sle
#[DEBUG] setting BETA=1
#[DEBUG] setting BETA_WE=1
#[DEBUG] setting QEMUCPU=qemu64
#[DEBUG] setting BUILD_HA=0179
#[DEBUG] setting BUILD_SDK=0230
#[DEBUG] setting REPO_0=SLE-12-SP3-Server-DVD-x86_64-Build0420-Media1
#[DEBUG] setting BETA_SDK=1
#[DEBUG] setting JOBTOKEN=vYHnbklcXeQXUOmu
#[DEBUG] setting SCC_URL=http://Server-0420.proxy.scc.suse.de
#[DEBUG] setting VNC=91
#[DEBUG] setting ARCH=x86_64
#[DEBUG] setting OPENQA_HOSTNAME=localhost
#[DEBUG] setting SLENKINS_TESTSUITES_REPO=http://download.suse.de/ibs/Devel:/SLEnkins:/testsuites/SLE_12_SP3/
#[DEBUG] setting SHUTDOWN_NEEDS_AUTH=1
#[DEBUG] setting VERSION=12-SP3
#[DEBUG] setting HDD_1=openqa_support_server_sles12sp1.x86_64.qcow2
#[DEBUG] setting BUILD_HA_GEO=0138
#[DEBUG] setting BUILD=0420
#[DEBUG] setting WORKER_CLASS=qemu_x86_64
#[DEBUG] setting SCC_REGCODE=30452ce234918d23
#[DEBUG] setting BACKEND=qemu
#[DEBUG] setting INSTALLCHECK=1
#[DEBUG] setting QA_HEAD_REPO=http://dist.nue.suse.com/ibs/QA:/Head/SLE-12-SP3
#[DEBUG] setting QEMUPORT=20012



use OpenQA::Worker::Common;
use OpenQA::Utils qw(locate_asset log_error log_info log_debug);

use POSIX qw(:sys_wait_h strftime uname _exit);
use JSON 'to_json';
use Fcntl;
use File::Spec::Functions 'catdir';
use File::Basename;
use Errno;
use Cwd qw(abs_path getcwd);
use OpenQA::Worker::Cache;
use Time::HiRes 'sleep';

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

# runs in a subprocess, so don't rely on setting variables, but return
sub cache_tests {
    my ($shared_cache, $testpoolserver) = @_;

    my $start = time;
    # Do an flock to ensure only one worker is trying to synchronize at a time.
    my @cmd = ('flock', "$shared_cache/needleslock");
    push @cmd, (qw(rsync -avHP), "$testpoolserver/", qw(--delete));
    push @cmd, "$shared_cache/tests/";

    log_debug("Calling " . join(' ', @cmd));
    my $res = system(@cmd);
    log_debug(sprintf("RSYNC: Synchronization of tests directory took %.2f seconds", time - $start));
    exit($res);
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

    $vars{PRJDIR} = $OpenQA::Utils::sharedir;
    my $error = locate_local_assets(\%vars, $assetkeys);
    return $error if $error;

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
        #DO (this is where the magic happens)
        #exec "perl", "$isotovideo", '-d';
        exec  "su - jail; cd ; build-and-test-wicked-with-slenkins.sh";
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
