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
use OpenQA::Utils qw(locate_asset log_error log_info log_debug get_channel_handle);

use POSIX qw(:sys_wait_h strftime uname _exit);
use Cpanel::JSON::XS 'encode_json';
use Fcntl;
use File::Spec::Functions 'catdir';
use File::Basename;
use Errno;
use Cwd qw(abs_path getcwd);
use OpenQA::Worker::Cache;
use Time::HiRes 'sleep';
use IO::Handle;
use Mojo::IOLoop::ReadWriteProcess 'process';
use Mojo::IOLoop::ReadWriteProcess::Session 'session';

my $isotovideo = "/usr/bin/isotovideo";
my $workerpid;

require Exporter;
our (@ISA, @EXPORT);
@ISA    = qw(Exporter);
@EXPORT = qw(engine_workit engine_check);

sub set_engine_exec {
    my ($path) = @_;
    if ($path) {
        die "Path to isotovideo invalid: $path" unless -f $path;
        # save the absolute path as we chdir later
        $isotovideo = abs_path($path);
    }
    $OpenQA::Worker::Common::isotovideo_interface_version = $1
      if (-f $isotovideo && qx(perl $isotovideo --version) =~ /interface v(\d+)/);
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

    print $fd Cpanel::JSON::XS->new->pretty(1)->encode(\%$vars);
    close($fd);
}

sub cache_assets {
    my ($vars, $assetkeys) = @_;

    for my $this_asset (sort keys %$assetkeys) {
        log_debug("Found $this_asset, caching " . $vars->{$this_asset});
        my $asset = get_asset($job, $assetkeys->{$this_asset}, $vars->{$this_asset});
        return {error => "Can't download $vars->{$this_asset}"} unless $asset;
        unlink basename($asset) if -l basename($asset);
        symlink($asset, basename($asset)) or die "cannot create link: $asset, $pooldir";
        $vars->{$this_asset} = catdir(getcwd, basename($asset));
    }
    return undef;
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

    session->enable;
    session->reset;
    session->enable_subreaper;

    my ($sysname, $hostname, $release, $version, $machine) = POSIX::uname();
    log_info('+++ setup notes +++', channels => 'autoinst');
    log_info(sprintf("start time: %s", strftime("%F %T", gmtime)), channels => 'autoinst');
    log_info(sprintf("running on $hostname:%d ($sysname $release $version $machine)", $instance),
        channels => 'autoinst');

    log_error("Failed enabling subreaper mode", channels => 'autoinst') unless session->subreaper;

    session->on(
        collected_orphan => sub {
            my ($session, $p) = @_;
            log_info("Collected unknown process with pid " . $p->pid . " and exit status: " . $p->exit_status,
                channels => 'autoinst');
        });

    # set base dir to the one assigned with webui
    OpenQA::Utils::change_sharedir($hosts->{$current_host}{dir});

    # XXX: this should come from the worker table. Only included
    # here for convenience when looking at the pool of
    # debugging.
    for my $i (qw(QEMUPORT VNC OPENQA_HOSTNAME)) {
        $job->{settings}->{$i} = $ENV{$i};
    }
    if (open(my $fh, '>', 'job.json')) {
        print $fh Cpanel::JSON::XS->new->pretty(1)->encode($job);
        close $fh;
    }

    # pass worker instance and worker id to isotovideo
    # both used to create unique MAC and TAP devices if needed
    # workerid is also used by libvirt backend to identify VMs
    my $openqa_url = $current_host;
    my $workerid   = $hosts->{$current_host}{workerid};
    my %vars       = (
        OPENQA_URL      => $openqa_url,
        WORKER_INSTANCE => $instance,
        WORKER_ID       => $workerid,
        PRJDIR          => $OpenQA::Utils::sharedir
    );
    while (my ($k, $v) = each %{$job->{settings}}) {
        log_debug("setting $k=$v");
        $vars{$k} = $v;
    }

    my $shared_cache;

    my $assetkeys = detect_asset_keys(\%vars);

    # do asset caching if CACHEDIRECTORY is set
    if ($worker_settings->{CACHEDIRECTORY}) {
        my $host_to_cache = Mojo::URL->new($current_host)->host;
        OpenQA::Worker::Cache::init($current_host, $worker_settings->{CACHEDIRECTORY});
        my $error = cache_assets(\%vars, $assetkeys);
        return $error if $error;

        # do test caching if TESTPOOLSERVER is set
        if ($hosts->{$current_host}{testpoolserver}) {
            $shared_cache = catdir($worker_settings->{CACHEDIRECTORY}, $host_to_cache);
            $vars{PRJDIR} = $shared_cache;

            my $rsync = process(sub { cache_tests($shared_cache, $hosts->{$current_host}{testpoolserver}) })->start;
            my $last_update = time;
            while (defined(my $line = $rsync->getline)) {
                log_info("rsync: " . $line, channels => 'autoinst');
                if (time - $last_update > 5) {
                    update_setup_status;
                    $last_update = time;
                }
            }

            $rsync->wait_stop;

            return {error => "Failed to rsync tests: exit " . $rsync->exit_status} unless $rsync->exit_status == 0;

            $shared_cache = catdir($shared_cache, 'tests');
        }
    }
    else {
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

    my $child = process(
        sub {
            setpgrp(0, 0);
            $ENV{TMPDIR} = $tmpdir;
            log_info("$$: WORKING " . $job->{id});
            log_debug('+++ worker notes +++', channels => 'autoinst');
            log_debug(sprintf("start time: %s", strftime("%F %T", gmtime)), channels => 'autoinst');

            my ($sysname, $hostname, $release, $version, $machine) = POSIX::uname();
            log_debug(sprintf("running on $hostname:%d ($sysname $release $version $machine)", $instance),
                channels => 'autoinst');
            my $handle = get_channel_handle('autoinst');
            STDOUT->fdopen($handle, 'w');
            STDERR->fdopen($handle, 'w');

            exec "perl", "$isotovideo", '-d';
            die "exec failed: $!\n";
        });

    $child->on(
        collected => sub {
            my $self = shift;
            log_info("Isotovideo exit status: " . $self->exit_status, channels => 'autoinst');
            if ($self->exit_status != 0) {
                OpenQA::Worker::Jobs::stop_job('died');
            }
            else {
                OpenQA::Worker::Jobs::stop_job('done');
            }
        });

    $child->_default_kill_signal(-POSIX::SIGTERM())->_default_blocking_signal(-POSIX::SIGKILL());
    $child->set_pipes(0)->internal_pipes(0)->blocking_stop(1)->start();

    $workerpid = $child->pid();
    return {child => $child};
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
