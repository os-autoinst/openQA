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

use OpenQA::Utils qw(base_host locate_asset log_error log_info log_debug log_warning get_channel_handle);
use POSIX qw(:sys_wait_h strftime uname _exit);
use Mojo::JSON 'encode_json';    # booleans
use Cpanel::JSON::XS ();
use Fcntl;
use File::Spec::Functions 'catdir';
use File::Basename;
use Errno;
use Cwd qw(abs_path getcwd);
use OpenQA::Worker::Cache;
use OpenQA::Worker::Cache::Client;
use OpenQA::Worker::Cache::Request;
use Time::HiRes 'sleep';
use IO::Handle;
use Mojo::IOLoop::ReadWriteProcess 'process';
use Mojo::IOLoop::ReadWriteProcess::Session 'session';
use Mojo::IOLoop::ReadWriteProcess::Container 'container';
use Mojo::IOLoop::ReadWriteProcess::CGroup 'cgroupv2';
use Mojo::Collection 'c';
use Mojo::File 'path';
use Mojo::Util 'trim';

use constant CGROUP_SLICE => $ENV{OPENQA_CGROUP_SLICE};

my $isotovideo = "/usr/bin/isotovideo";
my $workerpid;

sub set_engine_exec {
    my ($path) = @_;
    if ($path) {
        die "Path to isotovideo invalid: $path" unless -f $path;
        # save the absolute path as we chdir later
        $isotovideo = abs_path($path);
    }
    if (-f $isotovideo && qx(perl $isotovideo --version) =~ /interface v(\d+)/) {
        return $1;
    }
    return 0;
}

sub _kill($) {
    my ($pid) = @_;
    if (kill('TERM', $pid)) {
        warn "killed $pid - waiting for exit";
        waitpid($pid, 0);
    }
}

sub _save_vars {
    my ($pooldir, $vars) = @_;
    die "cannot get environment variables!\n" unless $vars;
    my $fn = $pooldir . "/vars.json";
    unlink "$pooldir/vars.json" if -e "$pooldir/vars.json";
    open(my $fd, ">", $fn)                                    or die "can not write vars.json: $!\n";
    fcntl($fd, F_SETLKW, pack('ssqql', F_WRLCK, 0, 0, 0, $$)) or die "cannot lock vars.json: $!\n";
    truncate($fd, 0)                                          or die "cannot truncate vars.json: $!\n";

    print $fd Cpanel::JSON::XS->new->pretty(1)->encode(\%$vars);
    close($fd);
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

    # UEFI_PFLASH_VARS may point to an image uploaded by a previous
    # test (which we should treat as an hdd asset), or it may point
    # to an absolute filesystem location of e.g. a template file from
    # edk2 (which we shouldn't).
    $res{UEFI_PFLASH_VARS} = 'hdd' if ($vars->{UEFI_PFLASH_VARS} && $vars->{UEFI_PFLASH_VARS} !~ m,^/,);

    return \%res;
}

sub cache_assets {
    my ($job, $vars, $assetkeys, $webui_host, $pooldir) = @_;
    my $cache_client = OpenQA::Worker::Cache::Client->new;
    # TODO: Enqueue all, and then wait
    for my $this_asset (sort keys %$assetkeys) {
        my $asset;
        my $asset_uri = trim($vars->{$this_asset});
        # Skip UEFI_PFLASH_VARS asset if the job won't use UEFI.
        next if (($this_asset eq 'UEFI_PFLASH_VARS') and !$vars->{UEFI});
        log_debug("Found $this_asset, caching " . $vars->{$this_asset});

        # check cache availability
        my $error = $cache_client->availability_error;
        return {error => $error} if $error;

        my $asset_request = $cache_client->request->asset(
            id    => $job->id,
            asset => $asset_uri,
            type  => $assetkeys->{$this_asset},
            host  => $webui_host
        );

        if ($asset_request->enqueue) {
            log_debug("Downloading $asset_uri - request sent to Cache Service.", channels => 'autoinst');
            until ($asset_request->processed) {
                sleep 5;
                return {error => 'Status updates interrupted'} unless $job->post_setup_status;
            }
            my $msg = "Download of $asset_uri processed";
            if (my $output = $asset_request->output) { $msg .= ": $output" }
            log_debug($msg, channels => 'autoinst');
        }

        $asset = $cache_client->asset_path($webui_host, $asset_uri)
          if $cache_client->asset_exists($webui_host, $asset_uri);

        if ($this_asset eq 'UEFI_PFLASH_VARS' && !defined $asset) {
            log_error("Failed to download $asset_uri");
            # assume that if we have a full path, that's what we should use
            $vars->{$this_asset} = $asset_uri if -e $asset_uri;
            # don't kill the job if the asset is not found
            # TODO: This seems to leave the job stuck in some cases (observed in production on openqaworker3).
            next;
        }
        return {error => "Failed to download $asset_uri to " . $cache_client->asset_path($webui_host, $asset_uri)}
          unless $asset;
        unlink basename($asset) if -l basename($asset);
        symlink($asset, basename($asset)) or die "cannot create link: $asset, $pooldir";
        $vars->{$this_asset} = path(getcwd, basename($asset))->to_string;
    }
    return undef;
}

sub engine_workit {
    my ($job)           = @_;
    my $worker          = $job->worker;
    my $client          = $job->client;
    my $global_settings = $worker->settings->global_settings;
    my $pooldir         = $worker->pool_directory;
    my $instance        = $worker->instance_number;
    my $workerid        = $client->worker_id;
    my $webui_host      = $client->webui_host;
    my $job_info        = $job->info;

    log_debug('Preparing Mojo::IOLoop::ReadWriteProcess::Session');
    session->enable;
    session->reset;
    session->enable_subreaper;

    my ($sysname, $hostname, $release, $version, $machine) = POSIX::uname();
    log_info('+++ setup notes +++', channels => 'autoinst');
    log_info(sprintf("Start time: %s", strftime("%F %T", gmtime)), channels => 'autoinst');
    log_info(sprintf("Running on $hostname:%d ($sysname $release $version $machine)", $instance),
        channels => 'autoinst');

    log_error("Failed enabling subreaper mode", channels => 'autoinst') unless session->subreaper;

    # XXX: this should come from the worker table. Only included
    # here for convenience when looking at the pool of
    # debugging.
    my $job_settings = $job_info->{settings};
    for my $i (qw(QEMUPORT VNC OPENQA_HOSTNAME)) {
        $job_settings->{$i} = $ENV{$i};
    }
    if (open(my $fh, '>', 'job.json')) {
        print $fh Cpanel::JSON::XS->new->pretty(1)->encode($job_info);
        close $fh;
    }

    # pass worker instance and worker id to isotovideo
    # both used to create unique MAC and TAP devices if needed
    # workerid is also used by libvirt backend to identify VMs
    my $openqa_url = $webui_host;
    my %vars       = (
        OPENQA_URL      => $openqa_url,
        WORKER_INSTANCE => $instance,
        WORKER_ID       => $workerid,
        PRJDIR          => $OpenQA::Utils::sharedir,
        %$job_settings
    );
    log_debug('Job settings:');
    log_debug(join("\n", '', map { "    $_=$vars{$_}" } sort keys %vars));

    my $shared_cache;

    my $assetkeys = detect_asset_keys(\%vars);

    # do asset caching if CACHEDIRECTORY is set
    if ($global_settings->{CACHEDIRECTORY}) {
        my $host_to_cache = base_host($webui_host);
        my $error         = cache_assets($job, \%vars, $assetkeys, $webui_host, $pooldir);
        return $error if $error;

        # do test caching if TESTPOOLSERVER is set
        if (my $rsync_source = $client->testpool_server) {
            $shared_cache = catdir($global_settings->{CACHEDIRECTORY}, $host_to_cache);

            my $cache_client  = OpenQA::Worker::Cache::Client->new;
            my $rsync_request = $cache_client->request->rsync(
                from => $rsync_source,
                to   => $shared_cache
            );
            my $rsync_request_description = "Rsync cache request from '$rsync_source' to '$shared_cache'";

            $vars{PRJDIR} = $shared_cache;

            # enqueue rsync task; retry in some error cases
            for (my $remaining_tries = 3; $remaining_tries > 0; --$remaining_tries) {
                return {error => "Failed to send $rsync_request_description"} unless $rsync_request->enqueue;
                log_info("Enqueued $rsync_request_description");

                until ($rsync_request->processed) {
                    sleep 5;
                    return {error => 'Status updates interrupted'} unless $job->post_setup_status;
                }

                if (my $output = $rsync_request->output) {
                    log_info('Output of rsync: ' . $output, channels => 'autoinst');
                }

                # treat "no sync necessary" as success as well
                my $exit = $rsync_request->result // 0;

                if (!defined $exit) {
                    return {error => 'Failed to rsync tests.'};
                }
                elsif ($exit == 0) {
                    log_info('Finished to rsync tests');
                    last;
                }
                elsif ($remaining_tries > 1 && $exit == 24) {
                    log_info("Rsync failed due to a vanished source files (exit code 24), trying again");
                }
                else {
                    return {error => "Failed to rsync tests: exit code: $exit"};
                }
            }


            $shared_cache = catdir($shared_cache, 'tests');
        }
    }
    else {
        my $error = locate_local_assets(\%vars, $assetkeys);
        return $error if $error;
    }

    $vars{ASSETDIR}   //= $OpenQA::Utils::assetdir;
    $vars{CASEDIR}    //= OpenQA::Utils::testcasedir($vars{DISTRI}, $vars{VERSION}, $shared_cache);
    $vars{PRODUCTDIR} //= OpenQA::Utils::productdir($vars{DISTRI}, $vars{VERSION}, $shared_cache);

    _save_vars($pooldir, \%vars);

    # os-autoinst's commands server
    $job_info->{URL}
      = "http://localhost:" . ($job_info->{settings}->{QEMUPORT} + 1) . "/" . $job_info->{settings}->{JOBTOKEN};

    # create cgroup within /sys/fs/cgroup/systemd
    log_info('Preparing cgroup to start isotovideo');
    my $cgroup_name  = 'systemd';
    my $cgroup_slice = CGROUP_SLICE;
    if (!defined $cgroup_slice) {
        # determine cgroup slice of the current process
        eval {
            my $pid = $$;
            $cgroup_slice = (grep { /name=$cgroup_name:/ } split(/\n/, path('/proc', $pid, 'cgroup')->slurp))[0]
              if defined $pid;
            $cgroup_slice =~ s/^.*name=$cgroup_name:/$cgroup_name/g if defined $cgroup_slice;
        };
    }
    my $cgroup;
    eval {
        $cgroup = cgroupv2(name => $cgroup_name)->from($cgroup_slice)->child($job_info->{id})->create;
        if (my $query_cgroup_path = $cgroup->can('_cgroup')) {
            log_info('Using cgroup ' . $query_cgroup_path->($cgroup));
        }
    };
    if (my $error = $@) {
        $cgroup = c();
        log_warning("Disabling cgroup usage because cgroup creation failed: $error");
        log_info(
            'You can define a custom slice with OPENQA_CGROUP_SLICE or indicating the base mount with MOJO_CGROUP_FS.');
    }

    # create tmpdir for QEMU
    my $tmpdir = "$pooldir/tmp";
    mkdir($tmpdir) unless (-d $tmpdir);

    my $child = process(
        sub {
            setpgrp(0, 0);
            $ENV{TMPDIR} = $tmpdir;
            log_info("$$: WORKING " . $job_info->{id});
            log_debug('+++ worker notes +++', channels => 'autoinst');
            log_debug(sprintf("Start time: %s", strftime("%F %T", gmtime)), channels => 'autoinst');

            my ($sysname, $hostname, $release, $version, $machine) = POSIX::uname();
            log_debug(sprintf("Running on $hostname:%d ($sysname $release $version $machine)", $instance),
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
                $job->stop('died');
            }
            else {
                $job->stop('done');
            }
        });

    session->on(
        register => sub {
            shift;
            eval { log_debug("Registered process:" . shift->pid, channels => 'worker'); };
        });

    # disable additional pipes for process communication and retrieving process return/errors
    $child->set_pipes(0);
    $child->internal_pipes(0);

    # configure how to stop the process again: attempt to send SIGTERM 5 times, fall back to SIGKILL
    # after 5 seconds
    $child->_default_kill_signal(-POSIX::SIGTERM());
    $child->_default_blocking_signal(-POSIX::SIGKILL());
    $child->max_kill_attempts(5);
    $child->blocking_stop(1);
    $child->kill_sleeptime(5);

    my $container
      = container(clean_cgroup => 1, pre_migrate => 1, cgroups => $cgroup, process => $child, subreaper => 0);

    $container->on(
        container_error => sub { shift; my $e = shift; log_error("Container error: @{$e}", channels => 'worker') });

    log_info('Starting isotovideo container');
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

1;
