# Copyright 2015-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Worker::Engines::isotovideo;
use Mojo::Base -base, -signatures;

use Mojo::Base -signatures;
use OpenQA::Constants qw(WORKER_SR_DONE WORKER_EC_CACHE_FAILURE WORKER_EC_ASSET_FAILURE WORKER_SR_DIED);
use OpenQA::Log qw(log_error log_info log_debug log_warning get_channel_handle);
use OpenQA::Utils
  qw(asset_type_from_setting base_host locate_asset looks_like_url_with_scheme testcasedir productdir needledir);
use POSIX qw(:sys_wait_h strftime uname _exit);
use Mojo::JSON 'encode_json';    # booleans
use Cpanel::JSON::XS ();
use Fcntl;
use File::Spec::Functions qw(abs2rel catdir file_name_is_absolute);
use File::Basename 'basename';
use Errno;
use Cwd 'abs_path';
use OpenQA::CacheService::Client;
use OpenQA::CacheService::Request;
use Time::HiRes 'sleep';
use IO::Handle;
use Module::Loaded 'is_loaded';
use Mojo::IOLoop::ReadWriteProcess 'process';
use Mojo::IOLoop::ReadWriteProcess::Session 'session';
use Mojo::IOLoop::ReadWriteProcess::Container 'container';
use Mojo::IOLoop::ReadWriteProcess::CGroup 'cgroupv2';
use Mojo::Collection 'c';
use Mojo::File 'path';
use Mojo::Util qw(trim scope_guard);

use constant CGROUP_SLICE => $ENV{OPENQA_CGROUP_SLICE};
use constant CACHE_SERVICE_POLL_DELAY => $ENV{OPENQA_CACHE_SERVICE_POLL_DELAY} // 5;
use constant CACHE_SERVICE_TEST_SYNC_ATTEMPTS => $ENV{OPENQA_CACHE_SERVICE_TEST_SYNC_ATTEMPTS} // 3;

my $isotovideo = '/usr/bin/isotovideo';
my $workerpid;

sub set_engine_exec ($path) {
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

sub _save_vars ($pooldir, $vars) {
    die 'cannot get environment variables!\n' unless $vars;
    my $fn = $pooldir . '/vars.json';
    unlink "$pooldir/vars.json" if -e "$pooldir/vars.json";
    open(my $fd, '>', $fn) or die "can not write vars.json: $!\n";
    fcntl($fd, F_SETLKW, pack('ssqql', F_WRLCK, 0, 0, 0, $$)) or die "cannot lock vars.json: $!\n";
    truncate($fd, 0) or die "cannot truncate vars.json: $!\n";

    print $fd Cpanel::JSON::XS->new->pretty(1)->encode(\%$vars);
    close($fd);
}

sub detect_asset_keys ($vars) {
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

sub _poll_cache_service ($job, $cache_client, $request, $delay, $callback) {
    # perform status updates while waiting and handle interruptions
    return $callback->({error => 'Status updates interrupted'}, undef) unless $job->post_setup_status;

    my $status = $cache_client->status($request);
    return Mojo::IOLoop->singleton->timer(
        $delay => sub { _poll_cache_service($job, $cache_client, $request, $delay, $callback) })
      unless $status->is_processed;
    return $callback->({error => 'Job has been cancelled'}, undef) if $job->is_stopped_or_stopping;
    return $callback->({error => $status->error}, undef) if $status->has_error;
    return $callback->(undef, $status);
}

sub cache_assets ($cache_client, $job, $vars, $assets_to_cache, $assetkeys, $webui_host, $pooldir, $callback) {
    return $callback->(undef) unless my $this_asset = shift @$assets_to_cache;
    return cache_assets(@_) unless my $asset_value = $vars->{$this_asset};

    my $asset_uri = trim($asset_value);
    # skip UEFI_PFLASH_VARS asset if the job won't use UEFI
    return cache_assets(@_) if $this_asset eq 'UEFI_PFLASH_VARS' && !$vars->{UEFI};
    # check cache availability
    my $error = $cache_client->info->availability_error;
    return $callback->({error => $error}) if $error;
    log_debug("Found $this_asset, caching $vars->{$this_asset}", channels => 'autoinst');

    my %params = (id => $job->id, asset => $asset_uri, type => $assetkeys->{$this_asset}, host => $webui_host);
    my $asset_request = $cache_client->asset_request(\%params);
    if (my $err = $cache_client->enqueue($asset_request)) {
        return $callback->({error => "Failed to send asset request for $asset_uri: $err"});
    }

    my $minion_id = $asset_request->minion_id;
    log_info("Downloading $asset_uri, request #$minion_id sent to Cache Service", channels => 'autoinst');
    return _poll_cache_service(
        $job,
        $cache_client,
        $asset_request,
        CACHE_SERVICE_POLL_DELAY,
        sub ($error, $status) {
            $error
              = _handle_asset_processed($cache_client, $assets_to_cache, $asset_uri, $status, $vars, $webui_host,
                $pooldir)
              unless $error;
            return $callback->($error) if $error;
            return cache_assets($cache_client, $job, $vars, $assets_to_cache, $assetkeys, $webui_host, $pooldir,
                $callback);
        });
}

sub _handle_asset_processed ($cache_client, $this_asset, $asset_uri, $status, $vars, $webui_host, $pooldir) {
    my $msg = "Download of $asset_uri processed";
    if (my $output = $status->output) { $msg .= ":\n$output" }
    log_info($msg, channels => 'autoinst');

    my $asset
      = $cache_client->asset_exists($webui_host, $asset_uri)
      ? $cache_client->asset_path($webui_host, $asset_uri)
      : undef;
    if ($this_asset eq 'UEFI_PFLASH_VARS' && !defined $asset) {
        log_error("Failed to download $asset_uri", channels => 'autoinst');
        # assume that if we have a full path, that's what we should use
        $vars->{$this_asset} = $asset_uri if -e $asset_uri;
        return undef;    # don't abort the job if the asset is not found
    }
    if (!$asset) {
        my $error = "Failed to download $asset_uri to " . $cache_client->asset_path($webui_host, $asset_uri);
        return {error => $error, category => WORKER_EC_ASSET_FAILURE} if $msg =~ qr/4\d\d /;
        # note: This check has no effect if the download was performed by
        # an already enqueued Minion job or if the pruning happened within
        # a completely different asset download.
        $error .= '. Asset was pruned immediately after download (poo#71827), please retrigger'
          if $msg =~ /Purging.*$asset_uri.*because we need space for new assets/;
        log_error($error, channels => 'autoinst');
        return {error => $error};
    }
    my $link_result = _link_asset($asset, $pooldir);
    $vars->{$this_asset}
      = $vars->{ABSOLUTE_TEST_CONFIG_PATHS} ? $link_result->{absolute_path} : $link_result->{basename};
    return undef;
}

sub _link_asset ($asset, $pooldir) {
    $asset = path($asset);
    $pooldir = path($pooldir);
    my $asset_basename = $asset->basename;
    my $target = $pooldir->child($asset_basename);

    # Prevent the syncing to abort e.g. for workers running with "--no-cleanup"
    unlink $target;

    # Try to use hardlinks first and only fall back to symlinks when that fails,
    # to ensure that assets cannot be purged early from the pool even if the
    # cache service runs out of space
    eval { link($asset, $target) or die qq{Cannot create link from "$asset" to "$target": $!} };
    if (my $err = $@) {
        symlink($asset, $target) or die qq{Cannot create symlink from "$asset" to "$target": $!};
        log_debug(qq{Symlinked asset because hardlink failed: $err});
    }
    log_debug(qq{Linked asset "$asset" to "$target"});

    return {basename => $asset_basename, absolute_path => $target->to_string};
}

sub _link_repo {
    my ($source_dir, $pooldir, $target_name) = @_;
    $pooldir = path($pooldir);
    my $target = $pooldir->child($target_name);
    unlink $target;
    return {error => "The source directory $source_dir does not exist"} unless -e $source_dir;
    return {error => qq{Cannot create symlink from "$source_dir" to "$target": $!}}
      unless symlink($source_dir, $target);
    log_debug(qq{Symlinked from "$source_dir" to "$target"});
    return undef;
}

# do test caching if TESTPOOLSERVER is set
sub sync_tests ($cache_client, $job, $vars, $shared_cache, $rsync_source, $remaining_tries, $callback) {
    my %rsync_retry_code = (
        10 => 'Error in socket I/O',
        23 => 'Partial transfer due to error',
        24 => 'Partial transfer due to vanished source files',
    );
    my $rsync_request = $cache_client->rsync_request(from => $rsync_source, to => $shared_cache);
    my $rsync_request_description = "from '$rsync_source' to '$shared_cache'";
    $job->worker->settings->global_settings->{PRJDIR} = $shared_cache;

    # enqueue rsync task; retry in some error cases
    if (my $err = $cache_client->enqueue($rsync_request)) {
        return $callback->({error => "Failed to send rsync $rsync_request_description: $err"});
    }
    my $minion_id = $rsync_request->minion_id;
    log_info("Rsync $rsync_request_description, request #$minion_id sent to Cache Service", channels => 'autoinst');

    return _poll_cache_service(
        $job,
        $cache_client,
        $rsync_request,
        CACHE_SERVICE_POLL_DELAY,
        sub ($error, $status) {
            return $callback->($error) if $error;

            if (my $output = $status->output) {
                log_info("Output of rsync:\n$output", channels => 'autoinst');
            }

            # treat "no sync necessary" as success as well
            my $result = $status->result // 'exit code 0';
            my $exit_code = $result =~ /exit code (\d+)/ ? $1 : undef;

            if ($result eq 'exit code 0') {
                log_info('Finished to rsync tests', channels => 'autoinst');
                return $callback->(catdir($shared_cache, 'tests'));
            }
            elsif ($remaining_tries > 1 && ($exit_code && $rsync_retry_code{$exit_code})) {
                log_info("$rsync_retry_code{$exit_code} ($result), trying again", channels => 'autoinst');
                return sync_tests($cache_client, $job, $vars, $shared_cache, $rsync_source, $remaining_tries - 1,
                    $callback);
            }
            else {
                my $error_msg = "Failed to rsync tests: $result";
                log_error($error_msg, channels => 'autoinst');
                return $callback->({error => $error_msg});
            }
        });
}

sub do_asset_caching ($job, $vars, $cache_dir, $assetkeys, $webui_host, $pooldir, $callback) {
    my $cache_client = OpenQA::CacheService::Client->new;
    cache_assets(
        $cache_client,
        $job, $vars,
        [sort keys %$assetkeys],
        $assetkeys,
        $webui_host,
        $pooldir,
        sub ($error) {
            return $callback->($error) if $error;
            my $rsync_source = $job->client->testpool_server;
            return $callback->(undef) unless $rsync_source;
            my $attempts = CACHE_SERVICE_TEST_SYNC_ATTEMPTS;
            my $shared_cache = catdir($cache_dir, base_host($webui_host));
            sync_tests($cache_client, $job, $vars, $shared_cache, $rsync_source, $attempts, $callback);
        });
}

sub engine_workit ($job, $callback) {
    my $worker = $job->worker;
    my $client = $job->client;
    my $global_settings = $worker->settings->global_settings;
    my $pooldir = $worker->pool_directory;
    my $instance = $worker->instance_number;
    my $workerid = $client->worker_id;
    my $webui_host = $client->webui_host;
    my $job_info = $job->info;

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
    my %vars = (
        OPENQA_URL => $openqa_url,
        WORKER_INSTANCE => $instance,
        WORKER_ID => $workerid,
        PRJDIR => OpenQA::Utils::sharedir(),
        %$job_settings
    );
    # note: PRJDIR is used as base for relative needle paths by os-autoinst. This is supposed to change
    #       but for compatibility with current old os-autoinst we need to set PRJDIR for a consistent
    #       behavior.

    log_debug('Job settings:');
    log_debug(join("\n", '', map { "    $_=$vars{$_}" } sort keys %vars));

    # cache/locate assets, set ASSETDIR
    my $assetkeys = detect_asset_keys(\%vars);
    if (my $cache_dir = $global_settings->{CACHEDIRECTORY}) {
        return do_asset_caching(
            $job,
            \%vars,
            $cache_dir,
            $assetkeys,
            $webui_host,
            $pooldir,
            sub ($shared_cache) {
                return _engine_workit_step_2($job, $job_settings, \%vars, $shared_cache, $callback)
                  unless ref $shared_cache eq 'HASH';
                $shared_cache->{category} //= WORKER_EC_CACHE_FAILURE;
                return $callback->($shared_cache);
            });
    }
    else {
        my $error = locate_local_assets(\%vars, $assetkeys, $pooldir);
        return $callback->($error) if $error;
    }

    return _engine_workit_step_2($job, $job_settings, \%vars, undef, $callback);
}

sub _configure_cgroupv2 ($job_info) {
    # create cgroup within /sys/fs/cgroup/systemd
    log_info('Preparing cgroup to start isotovideo');
    my $carp_guard;
    if (is_loaded('Carp::Always')) {
        $carp_guard = scope_guard sub { Carp::Always->import };    # uncoverable statement
        Carp::Always->unimport;    # uncoverable statement
    }
    my $cgroup_name = 'systemd';
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
        chomp $error;
        log_warning("Disabling cgroup usage because cgroup creation failed: $error");
        log_info(
            'You can define a custom slice with OPENQA_CGROUP_SLICE or indicating the base mount with MOJO_CGROUP_FS.');
    }
    return $cgroup;
}

sub _engine_workit_step_2 ($job, $job_settings, $vars, $shared_cache, $callback) {
    my $worker = $job->worker;
    my $pooldir = $worker->pool_directory;
    my $job_info = $job->info;

    $vars->{ASSETDIR} //= OpenQA::Utils::assetdir;

    # ensure a CASEDIR and a PRODUCTDIR is assigned and create a symlink if required
    my $absolute_paths = $vars->{ABSOLUTE_TEST_CONFIG_PATHS};
    my @vars_for_default_dirs = ($vars->{DISTRI}, $vars->{VERSION}, $shared_cache);
    my $default_casedir = testcasedir(@vars_for_default_dirs);
    my $default_productdir = productdir(@vars_for_default_dirs);
    my $target_name = path($default_casedir)->basename;
    my $has_custom_dir = $vars->{CASEDIR} || $vars->{PRODUCTDIR};
    my $casedir = $vars->{CASEDIR} //= $absolute_paths ? $default_casedir : $target_name;
    if ($casedir eq $target_name) {
        $vars->{PRODUCTDIR} //= substr($default_productdir, rindex($default_casedir, $target_name));
        if (my $error = _link_repo($default_casedir, $pooldir, $target_name)) { return $callback->($error) }
    }
    else {
        $vars->{PRODUCTDIR} //= $absolute_paths
          && !$has_custom_dir ? $default_productdir : abs2rel($default_productdir, $default_casedir);
    }

    # ensure a NEEDLES_DIR is assigned and create a symlink if required
    # explanation for the subsequent if-elsif conditions:
    # - If a custom CASEDIR/PRODUCTDIR has been specified, we still assume that a *relative* NEEDLES_DIR is
    #   relative to the default directory. In case the custom CASEDIR/PRODUCTDIR checkout would actually contain
    #   needles as well (instead of relying on a separate repository) one must *not* specify a custom NEEDLES_DIR
    #   and provide needles within the standard location (needles directory within custom PRODUCTDIR).
    # - If a custom CASEDIR/PRODUCTDIR has been specified but no custom NEEDLES_DIR we assume that the default
    #   needles directory is supposed to be used and make the assignment/symlink accordingly.
    # - If the specified NEEDLES_DIR is an absolute path or an URL we assume that it points to a custom location
    #   and keep it as-is.
    my $default_needles_dir = needledir(@vars_for_default_dirs);
    my $needles_dir = $vars->{NEEDLES_DIR};
    my $need_to_set_needles_dir = !$needles_dir && $has_custom_dir;
    if ($need_to_set_needles_dir && $absolute_paths) {
        # simply set the default needles dir when absolute paths are used
        $vars->{NEEDLES_DIR} = $default_needles_dir;
    }
    elsif ($need_to_set_needles_dir
        || ($needles_dir && !file_name_is_absolute($needles_dir) && !looks_like_url_with_scheme($needles_dir)))
    {
        # create/assign a symlink for needles if NEEDLES_DIR has been specified by the user as a path relative to
        # the default CASEDIR/PRODUCTDIR
        $vars->{NEEDLES_DIR} = $needles_dir = basename($needles_dir || 'needles');
        if (my $error = _link_repo($default_needles_dir, $pooldir, $needles_dir)) { return $callback->($error) }
    }
    _save_vars($pooldir, $vars);

    # os-autoinst's commands server
    $job_info->{URL}
      = 'http://localhost:' . ($job_settings->{QEMUPORT} + 1) . '/' . $job_settings->{JOBTOKEN};

    my $cgroup = _configure_cgroupv2($job_info);

    # create tmpdir for QEMU
    my $tmpdir = "$pooldir/tmp";
    mkdir($tmpdir) unless (-d $tmpdir);

    # create and configure the process including how to stop it again
    my $child = process(
        set_pipes => 0,    # disable additional pipes for process communication
        internal_pipes => 0,    # disable additional pipes for retrieving process return/errors
        kill_whole_group => 1,    # terminate/kill whole process group
        max_kill_attempts => 1,    # stop the process by sending SIGTERM one time …
        sleeptime_during_kill => .1,    # … and checking for termination every 100 ms …
        total_sleeptime_during_kill => 30,    # … for 30 seconds …
        kill_sleeptime => 0,    # … and wait not any longer …
        blocking_stop => 1,    # … before sending SIGKILL
        code => sub {
            setpgrp(0, 0);
            $ENV{TMPDIR} = $tmpdir;
            log_info("$$: WORKING " . $job_info->{id});
            log_debug('+++ worker notes +++', channels => 'autoinst');
            my $handle = get_channel_handle('autoinst');
            STDOUT->fdopen($handle, 'w');
            STDERR->fdopen($handle, 'w');

            # PERL5OPT may have Devel::Cover options, we don't need and want
            # them in the spawned process as it does not belong to openQA code
            local $ENV{PERL5OPT} = '';
            # Allow to override isotovideo executable with an arbitrary
            # command line based on a config option
            exec $job_settings->{ISOTOVIDEO} ? $job_settings->{ISOTOVIDEO} : ('perl', $isotovideo, '-d');
            die "exec failed: $!\n";
        });
    $child->on(
        collected => sub {
            my $self = shift;
            eval { log_info('Isotovideo exit status: ' . $self->exit_status, channels => 'autoinst'); };
            $job->stop($self->exit_status == 0 ? WORKER_SR_DONE : WORKER_SR_DIED);
        });

    session->on(
        register => sub {
            shift;
            eval { log_debug('Registered process:' . shift->pid, channels => 'worker'); };
        });

    my $container
      = container(clean_cgroup => 1, pre_migrate => 1, cgroups => $cgroup, process => $child, subreaper => 0);
    $container->on(
        container_error => sub { shift; my $e = shift; log_error("Container error: @{$e}", channels => 'worker') });

    log_info('Starting isotovideo container');
    $container->start();
    $workerpid = $child->pid();
    return $callback->({child => $child});
}

sub locate_local_assets ($vars, $assetkeys, $pooldir) {
    for my $key (keys %$assetkeys) {
        my $file = locate_asset($assetkeys->{$key}, $vars->{$key}, mustexist => 1);
        unless ($file) {
            next if (($key eq 'UEFI_PFLASH_VARS') and !$vars->{UEFI});
            my $error = "Cannot find $key asset $assetkeys->{$key}/$vars->{$key}!";
            log_error("$key handling $error", channels => 'autoinst');
            return {error => $error, category => WORKER_EC_ASSET_FAILURE};
        }
        if ($vars->{ABSOLUTE_TEST_CONFIG_PATHS}) {
            $vars->{$key} = $file;
            next;
        }
        my $link_result = _link_asset($file, $pooldir);
        $vars->{$key} = $link_result->{basename};
    }
    return undef;
}

1;
