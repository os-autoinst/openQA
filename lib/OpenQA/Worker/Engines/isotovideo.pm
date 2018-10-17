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
use OpenQA::Utils qw(locate_asset log_error log_info log_debug log_warning get_channel_handle trim);

use POSIX qw(:sys_wait_h strftime uname _exit);
use Cpanel::JSON::XS 'encode_json';
use Fcntl;
use File::Spec::Functions 'catdir';
use File::Basename;
use Errno;
use Cwd qw(abs_path getcwd);
use OpenQA::Worker::Cache;
use OpenQA::Worker::Cache::Client;
use OpenQA::Worker::Common;
use Time::HiRes 'sleep';
use IO::Handle;
use Mojo::IOLoop::ReadWriteProcess 'process';
use Mojo::IOLoop::ReadWriteProcess::Session 'session';
use Mojo::IOLoop::ReadWriteProcess::Container 'container';
use Mojo::IOLoop::ReadWriteProcess::CGroup 'cgroupv2';
use Mojo::Collection 'c';
use Mojo::File 'path';

use constant CGROUP_SLICE => $ENV{OPENQA_CGROUP_SLICE};

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

# When changing something here, also take a look at OpenQA::Utils::asset_type_from_setting
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

    $res{UEFI_PFLASH_VARS} = 'hdd' if $vars->{UEFI_PFLASH_VARS};

    return \%res;
}

sub cache_assets {
    my ($job, $vars, $assetkeys) = @_;
    my $cache_client = OpenQA::Worker::Cache::Client->new;
    for my $this_asset (sort keys %$assetkeys) {
        my $asset;
        my $asset_uri = trim($vars->{$this_asset});
        log_debug("Found $this_asset, caching " . $vars->{$this_asset});
        return {error => "Cache service not available."}            unless $cache_client->available;
        return {error => "No workers active in the cache service."} unless $cache_client->available_workers;

        if (
            $cache_client->enqueue_download(
                {
                    id    => $job->{id},
                    asset => $asset_uri,
                    type  => $assetkeys->{$this_asset},
                    host  => $current_host
                }))
        {
            log_debug("Downloading " . $asset_uri . " - request sent to Cache Service.", channels => 'autoinst');
            update_setup_status and sleep 5 until $cache_client->processed($asset_uri);
            log_debug("Download of " . $asset_uri . " processed",       channels => 'autoinst');
            log_debug($cache_client->asset_download_output($asset_uri), channels => 'autoinst');
        }

        $asset = $cache_client->asset_path($current_host, $asset_uri)
          if $cache_client->asset_exists($current_host, $asset_uri);

        if ($this_asset eq 'UEFI_PFLASH_VARS' && !defined $asset) {
            log_error("Can't download $asset_uri");
            # assume that if we have a full path, that's what we should use
            $vars->{$this_asset} = $asset_uri if -e $asset_uri;
            # don't kill the job if the asset is not found
            next;
        }
        return {error => "Can't download $asset_uri to " . $cache_client->asset_path($current_host, $asset_uri)}
          unless $asset;
        unlink basename($asset) if -l basename($asset);
        symlink($asset, basename($asset)) or die "cannot create link: $asset, $pooldir";
        $vars->{$this_asset} = path(getcwd, basename($asset))->to_string;
    }
    return;
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
        my $error = cache_assets($job => \%vars => $assetkeys);
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
    my $proc_cgroup;
    my $cgroup;
    mkdir($tmpdir) unless (-d $tmpdir);

    eval {
        $proc_cgroup = (grep { /name=systemd:/ } split(/\n/, path("/proc", $$, "cgroup")->slurp))[0];
        $proc_cgroup =~ s/^.*name=systemd:/systemd/g if defined $proc_cgroup;
    };

    local $@;
    eval { $cgroup = cgroupv2->from(CGROUP_SLICE // $proc_cgroup)->child($job->{id})->create; };
    $cgroup = c() and log_warning(
        "Failed creating CGroup subtree '$@', disabling them."
          . "You can define a custom slice with OPENQA_CGROUP_SLICE or indicating the base mount with MOJO_CGROUP_FS",
        channels => 'worker'
    ) if $@;

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
            eval { log_info("Isotovideo exit status: " . $self->exit_status, channels => 'autoinst'); };
            if ($self->exit_status != 0) {
                OpenQA::Worker::Jobs::stop_job('died');
            }
            else {
                OpenQA::Worker::Jobs::stop_job('done');
            }
        });

    session->on(
        register => sub {
            shift;
            eval { log_debug("Registered process:" . shift->pid, channels => 'worker'); };
        });

    $child->_default_kill_signal(-POSIX::SIGTERM())->_default_blocking_signal(-POSIX::SIGKILL());
    $child->set_pipes(0)->internal_pipes(0)->blocking_stop(1);

    my $container
      = container(clean_cgroup => 1, pre_migrate => 1, cgroups => $cgroup, process => $child, subreaper => 0);

    $container->on(
        container_error => sub { shift; my $e = shift; log_error("Container error: @{$e}", channels => 'worker') });

    $container->start();
    $workerpid = $child->pid();
    return {child => $child};
}

sub locate_local_assets {
    my ($vars, $assetkeys) = @_;

    for my $key (keys %$assetkeys) {
        my $file = locate_asset($assetkeys->{$key}, $vars->{$key}, mustexist => 1);
        unless ($file) {
            next if (($key eq 'UEFI_PFLASH_VARS') and !$vars->{UEFI});
            my $error = "Cannot find $key asset $assetkeys->{$key}/$vars->{$key}!";
            log_error("$key handling $error", channels => 'autoinst');
            return {error => $error};
        }
        $vars->{$key} = $file;
    }
    return undef;
}
