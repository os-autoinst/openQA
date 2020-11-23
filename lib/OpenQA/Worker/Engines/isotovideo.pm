# Copyright (C) 2015-2020 SUSE LLC
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

use OpenQA::Constants qw(WORKER_SR_DONE WORKER_SR_DIED);
use OpenQA::Log qw(log_error log_info log_debug log_warning get_channel_handle);
use OpenQA::Utils qw(asset_type_from_setting base_host locate_asset);
use POSIX qw(:sys_wait_h strftime uname _exit);
use Mojo::JSON 'encode_json';    # booleans
use Cpanel::JSON::XS ();
use Fcntl;
use File::Spec::Functions 'catdir';
use Errno;
use Cwd 'abs_path';
use OpenQA::CacheService::Client;
use OpenQA::CacheService::Request;
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

sub detect_asset_keys {
    my ($vars) = @_;

    my %res;

    for my $key (keys(%$vars)) {
        my $value = $vars->{$key};
        next unless $value;

        # UEFI_PFLASH_VARS may point to an image uploaded by a previous
        # test (which we should treat as an hdd asset), or it may point
        # to an absolute filesystem location of e.g. a template file from
        # edk2 (which we shouldn't).
        next if $key eq 'UEFI_PFLASH_VARS' && $value =~ m,^/,;
        my $type = asset_type_from_setting($key, $value);

        # Exclude repo assets for now because the cache service does not
        # handle directories
        next if $type eq 'repo' || !$type;
        $res{$key} = $type;
    }

    return \%res;
}

sub cache_assets {
    my ($job, $vars, $assetkeys, $webui_host, $pooldir) = @_;
    my $cache_client = OpenQA::CacheService::Client->new;
    for my $this_asset (sort keys %$assetkeys) {
        my $asset;
        my $asset_value = $vars->{$this_asset};
        next unless $asset_value;
        my $asset_uri = trim($asset_value);
        # Skip UEFI_PFLASH_VARS asset if the job won't use UEFI.
        next if (($this_asset eq 'UEFI_PFLASH_VARS') and !$vars->{UEFI});
        # check cache availability
        my $error = $cache_client->info->availability_error;
        return {error => $error} if $error;
        log_debug("Found $this_asset, caching $vars->{$this_asset}", channels => 'autoinst');

        my $asset_request = $cache_client->asset_request(
            id    => $job->id,
            asset => $asset_uri,
            type  => $assetkeys->{$this_asset},
            host  => $webui_host
        );
        if (my $err = $cache_client->enqueue($asset_request)) {
            return {error => "Failed to send asset request for $asset_uri: $err"};
        }

        my $minion_id = $asset_request->minion_id;
        log_info("Downloading $asset_uri, request #$minion_id sent to Cache Service", channels => 'autoinst');
        my $status = $cache_client->status($asset_request);
        until ($status->is_processed) {
            sleep 5;
            return {error => 'Status updates interrupted'} unless $job->post_setup_status;
            return {error => $status->error} if $status->has_error;
            $status = $cache_client->status($asset_request);
        }
        my $msg = "Download of $asset_uri processed";
        if (my $output = $status->output) { $msg .= ":\n$output" }
        log_info($msg, channels => 'autoinst');

        $asset = $cache_client->asset_path($webui_host, $asset_uri)
          if $cache_client->asset_exists($webui_host, $asset_uri);

        if ($this_asset eq 'UEFI_PFLASH_VARS' && !defined $asset) {
            log_error("Failed to download $asset_uri", channels => 'autoinst');
            # assume that if we have a full path, that's what we should use
            $vars->{$this_asset} = $asset_uri if -e $asset_uri;
            # don't kill the job if the asset is not found
            # TODO: This seems to leave the job stuck in some cases (observed in production on openqaworker3).
            next;
        }
        if (!$asset) {
            $error = "Failed to download $asset_uri to " . $cache_client->asset_path($webui_host, $asset_uri);
            # note: This check has no effect if the download was performed by
            # an already enqueued Minion job or if the pruning happened within
            # a completely different asset download.
            $error .= '. Asset was pruned immediately after download (poo#71827), please retrigger'
              if $msg =~ /Purging.*$asset_uri/;
            log_error($error, channels => 'autoinst');
            return {error => $error};
        }
        $vars->{$this_asset} = _link_asset($asset, $pooldir);
    }
    return undef;
}

sub _link_asset {
    my ($asset, $pooldir) = @_;

    $asset   = path($asset);
    $pooldir = path($pooldir);
    my $target = $pooldir->child($asset->basename);

    # Prevent the syncing to abort e.g. for workers running with "--no-cleanup"
    unlink $target if -e $target;

    # Try to use hardlinks first and only fall back to symlinks when that fails,
    # to ensure that assets cannot be purged early from the pool even if the
    # cache service runs out of space
    eval { link($asset, $target) or die qq{Cannot create link from "$asset" to "$target": $!} };
    if (my $err = $@) {
        symlink($asset, $target) or die qq{Cannot create symlink from "$asset" to "$target": $!};
        log_debug(qq{Symlinked asset because hardlink failed: $err});
    }
    log_debug(qq{Linked asset "$asset" to "$target"});

    return $target->to_string;
}

# do test caching if TESTPOOLSERVER is set
sub sync_tests {
    my ($job, $vars, $cache_dir, $webui_host, $rsync_source) = @_;
    my %rsync_retry_code = (
        10 => 'Error in socket I/O',
        23 => 'Partial transfer due to error',
        24 => 'Partial transfer due to vanished source files',
    );
    my $shared_cache  = catdir($cache_dir, base_host($webui_host));
    my $cache_client  = OpenQA::CacheService::Client->new;
    my $rsync_request = $cache_client->rsync_request(
        from => $rsync_source,
        to   => $shared_cache
    );
    my $rsync_request_description = "from '$rsync_source' to '$shared_cache'";
    $job->worker->settings->global_settings->{PRJDIR} = $shared_cache;

    # enqueue rsync task; retry in some error cases
    for (my $remaining_tries = 3; $remaining_tries > 0; --$remaining_tries) {
        if (my $err = $cache_client->enqueue($rsync_request)) {
            return {error => "Failed to send rsync $rsync_request_description: $err"};
        }
        my $minion_id = $rsync_request->minion_id;
        log_info("Rsync $rsync_request_description, request #$minion_id sent to Cache Service", channels => 'autoinst');

        my $status = $cache_client->status($rsync_request);
        until ($status->is_processed) {
            sleep 5;
            return {error => 'Status updates interrupted'} unless $job->post_setup_status;
            return {error => $status->error} if $status->has_error;
            $status = $cache_client->status($rsync_request);
        }

        if (my $output = $status->output) {
            log_info("Output of rsync:\n$output", channels => 'autoinst');
        }

        # treat "no sync necessary" as success as well
        my $result    = $status->result // 'exit code 0';
        my $exit_code = $result =~ /exit code (\d+)/ ? $1 : undef;

        if ($result eq 'exit code 0') {
            log_info('Finished to rsync tests', channels => 'autoinst');
            last;
        }
        elsif ($remaining_tries > 1 && ($exit_code && $rsync_retry_code{$exit_code})) {
            log_info("$rsync_retry_code{$exit_code} ($result), trying again", channels => 'autoinst');
        }
        else {
            my $error_msg = "Failed to rsync tests: $result";
            log_error($error_msg, channels => 'autoinst');
            return {error => $error_msg};
        }
    }
    return catdir($shared_cache, 'tests');
}

sub do_asset_caching {
    my ($job, $vars, $cache_dir, $assetkeys, $webui_host, $pooldir) = @_;
    die "Need parameters" unless $job;
    my $error = cache_assets($job, $vars, $assetkeys, $webui_host, $pooldir);
    return $error if $error;
    if (my $rsync_source = $job->client->testpool_server) {
        return sync_tests($job, $vars, $cache_dir, $webui_host, $rsync_source);
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
        PRJDIR          => OpenQA::Utils::sharedir(),
        %$job_settings
    );
    # note: PRJDIR is used as base for relative needle paths by os-autoinst. This is supposed to change
    #       but for compatibility with current old os-autoinst we need to set PRJDIR for a consistent
    #       behavior.

    log_debug('Job settings:');
    log_debug(join("\n", '', map { "    $_=$vars{$_}" } sort keys %vars));

    my $shared_cache;
    my $assetkeys = detect_asset_keys(\%vars);
    if (my $cache_dir = $global_settings->{CACHEDIRECTORY}) {
        $shared_cache = do_asset_caching($job, \%vars, $cache_dir, $assetkeys, $webui_host, $pooldir);
        return $shared_cache if (ref($shared_cache) eq 'HASH');
    }
    else {
        my $error = locate_local_assets(\%vars, $assetkeys);
        return $error if $error;
    }

    # record INIT_PRODUCTDIR in case when cloning a job which run on remote worker cannot find the needle_dir
    # See: https://progress.opensuse.org/issues/67723
    my $init_productdir = OpenQA::Utils::productdir($vars{DISTRI}, $vars{VERSION}, $shared_cache);
    $vars{INIT_PRODUCTDIR} = $init_productdir;
    $vars{ASSETDIR}   //= OpenQA::Utils::assetdir();
    $vars{CASEDIR}    //= OpenQA::Utils::testcasedir($vars{DISTRI}, $vars{VERSION}, $shared_cache);
    $vars{PRODUCTDIR} //= $init_productdir;

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

    # create and configure the process including how to stop it again
    my $child = process(
        set_pipes                   => 0,      # disable additional pipes for process communication
        internal_pipes              => 0,      # disable additional pipes for retrieving process return/errors
        kill_whole_group            => 1,      # terminate/kill whole process group
        max_kill_attempts           => 1,      # stop the process by sending SIGTERM one time …
        sleeptime_during_kill       => .1,     # … and checking for termination every 100 ms …
        total_sleeptime_during_kill => 30,     # … for 30 seconds …
        kill_sleeptime              => 0,      # … and wait not any longer …
        blocking_stop               => 1,      # … before sending SIGKILL
        code                        => sub {
            setpgrp(0, 0);
            $ENV{TMPDIR} = $tmpdir;
            log_info("$$: WORKING " . $job_info->{id});
            log_debug('+++ worker notes +++', channels => 'autoinst');
            my $handle = get_channel_handle('autoinst');
            STDOUT->fdopen($handle, 'w');
            STDERR->fdopen($handle, 'w');

            # PERL5OPT may have Devel::Cover options, we don't need and want
            # them in the spawned process as it does not belong to openQA code
            local $ENV{PERL5OPT} = "";
            exec "perl", "$isotovideo", '-d';
            die "exec failed: $!\n";
        });
    $child->on(
        collected => sub {
            my $self = shift;
            eval { log_info("Isotovideo exit status: " . $self->exit_status, channels => 'autoinst'); };
            $job->stop($self->exit_status == 0 ? WORKER_SR_DONE : WORKER_SR_DIED);
        });

    session->on(
        register => sub {
            shift;
            eval { log_debug("Registered process:" . shift->pid, channels => 'worker'); };
        });

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
