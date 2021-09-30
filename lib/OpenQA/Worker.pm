# Copyright 2015-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Worker;
use Mojo::Base -base, -signatures;

BEGIN {
    use Socket;
    use Scalar::Util;
    use OpenQA::Log qw(log_debug);
    use Mojo::Util qw(monkey_patch);

    # workaround getaddrinfo() being stuck in error state "Address family for hostname not supported"
    # for local connections (see https://progress.opensuse.org/issues/78390#note-38)
    my $original = \&Socket::getaddrinfo;
    monkey_patch 'Socket', getaddrinfo => sub {
        my ($node, $service, $hints) = @_;
        return $original->(@_) unless defined $node && $node eq '127.0.0.1';
        log_debug("Running patched getaddrinfo() for $node");
        my ($family, $socktype, $protocol, $flags) = @$hints{qw(family socktype protocol flags)};
        return Scalar::Util::dualvar(Socket::EAI_FAMILY(), 'ai_family not supported')
          unless !$family || $family == Socket::AF_INET();
        return (
            Scalar::Util::dualvar(0, ''),
            {
                family => $family || Socket::AF_INET(),
                protocol => $protocol || 0,
                socktype => Socket::SOCK_STREAM(),
                canonname => undef,
                addr => Socket::pack_sockaddr_in($service, Socket::inet_aton($node))});
    };
}

use POSIX 'uname';
use Fcntl;
use File::Path qw(make_path remove_tree);
use File::Spec::Functions 'catdir';
use Mojo::IOLoop;
use Mojo::File 'path';
use Try::Tiny;
use Scalar::Util 'looks_like_number';
use OpenQA::Constants
  qw(WEBSOCKET_API_VERSION WORKER_COMMAND_QUIT WORKER_SR_BROKEN WORKER_SR_DONE WORKER_SR_DIED WORKER_SR_FINISH_OFF MAX_TIMER MIN_TIMER);
use OpenQA::Client;
use OpenQA::Log qw(log_error log_warning log_info log_debug add_log_channel remove_log_channel);
use OpenQA::Utils qw(prjdir);
use OpenQA::Worker::WebUIConnection;
use OpenQA::Worker::Settings;
use OpenQA::Worker::Job;
use OpenQA::Worker::App;

has 'instance_number';
has 'pool_directory';
has 'no_cleanup';
has 'app';
has 'settings';
has 'clients_by_webui_host';
has 'current_webui_host';
has 'current_job';
has 'current_error';
has 'worker_hostname';
has 'isotovideo_interface_version';

sub new {
    my ($class, $cli_options) = @_;

    # determine uname info
    my ($sysname, $hostname, $release, $version, $machine) = POSIX::uname();

    # determine instance number
    my $instance_number = $cli_options->{instance};
    die 'no instance number specified' unless defined $instance_number;
    die "the specified instance number \"$instance_number\" is no number" unless looks_like_number($instance_number);

    # determine settings and create app
    my $settings = OpenQA::Worker::Settings->new($instance_number, $cli_options);
    my $app = OpenQA::Worker::App->new(
        mode => 'production',
        log_name => 'worker',
        instance => $instance_number,
    );
    $settings->apply_to_app($app);

    # setup the isotovideo engine
    # FIXME: Get rid of the concept of engines in the worker.
    my $isotovideo_interface_version = OpenQA::Worker::Engines::isotovideo::set_engine_exec($cli_options->{isotovideo});

    my $self = $class->SUPER::new(
        instance_number => $instance_number,
        no_cleanup => $cli_options->{'no-cleanup'},
        pool_directory => prjdir() . "/pool/$instance_number",
        app => $app,
        settings => $settings,
        clients_by_webui_host => undef,
        worker_hostname => $hostname,
        isotovideo_interface_version => $isotovideo_interface_version,
    );
    $self->{_cli_options} = $cli_options;
    $self->{_pool_directory_lock_fd} = undef;
    $self->{_shall_terminate} = 0;
    $self->{_finishing_off} = undef;
    $self->{_pending_jobs} = [];
    $self->{_pending_job_ids} = {};
    $self->{_jobs_to_skip} = {};

    return $self;
}

# logs the basic configuration of the worker instance
sub log_setup_info {
    my ($self) = @_;

    my $instance = $self->instance_number;
    my $settings = $self->settings;
    my $msg = "worker $instance:";
    $msg .= "\n - config file:           " . ($settings->file_path // 'not found');
    $msg .= "\n - worker hostname:       " . $self->worker_hostname;
    $msg .= "\n - isotovideo version:    " . $self->isotovideo_interface_version;
    $msg .= "\n - websocket API version: " . WEBSOCKET_API_VERSION;
    $msg .= "\n - web UI hosts:          " . join(',', @{$settings->webui_hosts});
    $msg .= "\n - class:                 " . ($settings->global_settings->{WORKER_CLASS} // '?');
    $msg .= "\n - no cleanup:            " . ($self->no_cleanup ? 'yes' : 'no');
    $msg .= "\n - pool directory:        " . $self->pool_directory;
    log_info($msg);

    my $parse_errors = $settings->parse_errors;
    log_error(join("\n - ", 'Errors occurred when reading config file:', @$parse_errors)) if (@$parse_errors);

    return $msg;
}

# determines the worker's capabilities
sub capabilities {
    my ($self) = @_;

    my $cached_caps = $self->{_caps};
    my $caps = $cached_caps // {
        host => $self->worker_hostname,
        instance => $self->instance_number,
        websocket_api_version => WEBSOCKET_API_VERSION,
        isotovideo_interface_version => $self->isotovideo_interface_version,
    };

    # pass current and pending jobs if present; this should prevent the web UI to mark these jobs as
    # incomplete despite the re-registration
    my @job_ids;
    my $current_job = $self->current_job;
    my $job_state = $current_job ? $current_job->status : undef;
    if ($job_state && $job_state ne 'new' && $job_state ne 'stopped') {
        push(@job_ids, $current_job->id);
    }
    push(@job_ids, @{$self->pending_job_ids});
    if (@job_ids) {
        $caps->{job_id} = @job_ids > 1 ? \@job_ids : $job_ids[0];
    }
    else {
        delete $caps->{job_id};
    }

    # do not update subsequent values; just return the previously cached values
    return $caps if $cached_caps;

    # determine CPU info
    my $global_settings = $self->settings->global_settings;
    if (my $arch = $global_settings->{ARCH}) {
        $caps->{cpu_arch} = $arch;
    }
    else {
        open(my $LSCPU, "-|", "LC_ALL=C lscpu");
        for my $line (<$LSCPU>) {
            chomp $line;
            if ($line =~ m/Model name:\s+(.+)$/) {
                $caps->{cpu_modelname} = $1;
            }
            if ($line =~ m/Architecture:\s+(.+)$/) {
                $caps->{cpu_arch} = $1;
            }
            if ($line =~ m/CPU op-mode\(s\):\s+(.+)$/) {
                $caps->{cpu_opmode} = $1;
            }
            if ($line =~ m/Flags:\s+(.+)$/) {
                $caps->{cpu_flags} = $1;
            }
        }
        close($LSCPU);
    }

    # determine memory limit
    open(my $MEMINFO, "<", "/proc/meminfo");
    for my $line (<$MEMINFO>) {
        chomp $line;
        if ($line =~ m/MemTotal:\s+(\d+).+kB/) {
            my $mem_max = $1 ? $1 : '';
            $caps->{mem_max} = int($mem_max / 1024) if $mem_max;
        }
    }
    close($MEMINFO);

    # determine worker class ...
    if (my $worker_class = $global_settings->{WORKER_CLASS}) {
        # ... from settings
        $caps->{worker_class} = $worker_class;
    }
    else {
        # ... from CPU architecture
        my %supported_archs_by_cpu_archs = (
            i586 => ['i586'],
            i686 => ['i686', 'i586'],
            x86_64 => ['x86_64', 'i686', 'i586'],

            ppc => ['ppc'],
            ppc64 => ['ppc64le', 'ppc64', 'ppc'],
            ppc64le => ['ppc64le', 'ppc64', 'ppc'],

            s390 => ['s390'],
            s390x => ['s390x', 's390'],

            aarch64 => ['aarch64'],
        );
        $caps->{worker_class}
          = join(',', map { 'qemu_' . $_ } @{$supported_archs_by_cpu_archs{$caps->{cpu_arch}} // [$caps->{cpu_arch}]});
        # TODO: check installed qemu and kvm?
    }

    return $self->{_caps} = $caps;
}

sub status {
    my ($self) = @_;

    my %status = (type => 'worker_status');
    if (my $current_job = $self->current_job) {
        $status{status} = 'working';
        $status{current_webui_host} = $self->current_webui_host;
        $status{job} = $current_job->info;
    }
    elsif (my $availability_error = $self->check_availability) {
        $status{status} = 'broken';
        $self->current_error($status{reason} = $availability_error);
    }
    else {
        $status{status} = 'free';
        $self->current_error(undef);
    }
    my $pending_job_ids = $self->{_pending_job_ids};
    $status{pending_job_ids} = $pending_job_ids if keys %$pending_job_ids;
    return \%status;
}

# initializes the worker so it does its thing when the Mojo::IOLoop is started
# note: Do not change the settings - especially the web UI hosts after calling this function.
sub init {
    my ($self) = @_;
    my $return_code = 0;

    # instantiate a client for each web UI we need to connect to
    my $settings = $self->settings;
    my $webui_hosts = $settings->webui_hosts;
    die 'no web UI hosts configured' unless @$webui_hosts;

    my %clients_by_webui_host
      = map { $_ => OpenQA::Worker::WebUIConnection->new($_, $self->{_cli_options}) } @$webui_hosts;
    $self->clients_by_webui_host(\%clients_by_webui_host);

    # register event handler
    for my $host (@$webui_hosts) {
        $clients_by_webui_host{$host}->on(status_changed => sub { $self->_handle_client_status_changed(@_) });
    }

    # check the setup (pool directory, worker cache, ...)
    # note: This assigns $self->current_error if there's an error and therefore prevents us from grabbing
    #       a job while broken. The error is propagated to the web UIs.
    $self->configure_cache_client;
    $self->current_error($self->check_availability);
    log_error $self->current_error if $self->current_error;

    # register error handler to stop the current job when a critical/unhandled error occurs
    Mojo::IOLoop->singleton->reactor->on(
        error => sub {
            my ($reactor, $err) = @_;
            $return_code = 1;

            # try to stop gracefully
            my $fatal_error = 'Another error occurred when trying to stop gracefully due to an error';
            if (!$self->{_shall_terminate} || $self->{_finishing_off}) {
                eval {
                    # log error using print because logging utils might have caused the exception
                    # (no need to repeat $err, it is printed anyways)
                    log_error('Stopping because a critical error occurred.');

                    # try to stop the job nicely
                    return $self->stop('exception');
                };
                $fatal_error = "$fatal_error: $@" if $@;
            }

            # kill if stopping gracefully does not work
            chomp $fatal_error;
            log_error($fatal_error);
            log_error('Trying to kill ourself forcefully now');
            $self->kill;
        });


    my $global_settings = $settings->global_settings;
    my $webui_host_specific_settings = $settings->webui_host_specific_settings;

    # Store the packages list of the environment the worker runs in
    if (my $cmd = $global_settings->{PACKAGES_CMD}) {
        my $pool_directory = $self->pool_directory;
        log_info("Gathering package information: $cmd");

        my $packages_filename = $pool_directory . '/worker_packages.txt';
        if (system("$cmd > $packages_filename") != 0) {
            log_error('The PACKAGES_CMD command could not be executed');
            return 1;
        }
        unless (-s $packages_filename) {
            log_error('The PACKAGES_CMD command doesn\'t return any data');
            return 1;
        }
    }

    # initialize clients to connect to the web UIs
    for my $host (@$webui_hosts) {
        die "settings for $host not correctly initialized\n"
          unless my $host_settings = $webui_host_specific_settings->{$host};
        die "client for $host not correctly initialized\n" unless my $client = $clients_by_webui_host{$host};
        next unless $client->status eq 'new';

        # check if host's working directory exists if caching is not enabled
        if ($global_settings->{CACHEDIRECTORY}) {
            $client->cache_directory(_prepare_cache_directory($host, $global_settings->{CACHEDIRECTORY}));
        }

        # find working directory for host
        # note: This is being also duplicated by OpenQA::Test::Utils since 49c06362d.
        my @working_dirs = ($host_settings->{SHARE_DIRECTORY}, catdir(prjdir(), 'share'));
        my ($working_dir) = grep { $_ && -d } @working_dirs;
        unless ($working_dir) {
            $_ and log_debug("Found possible working directory for $host: $_") for @working_dirs;
            log_error("Ignoring host '$host': Working directory does not exist.");
            next;
        }
        $client->working_directory($working_dir);
        log_info("Project dir for host $host is $working_dir");

        # assign other properties of the client
        $client->worker($self);
        $client->testpool_server($host_settings->{TESTPOOLSERVER});

        # schedule registration of the web UI host
        Mojo::IOLoop->next_tick(
            sub {
                $client->register();
            });
    }

    return $return_code;
}

sub configure_cache_client {
    my ($self) = @_;

    # init cache service client for availability check if a cache directory is configured
    # note: Reducing default timeout and attempts to avoid worker from becoming unresponsive. Otherwise it
    #       would appear to be stuck and not even respond to signals.
    return delete $self->{_cache_service_client} unless $self->settings->global_settings->{CACHEDIRECTORY};
    my $client = $self->{_cache_service_client} = OpenQA::CacheService::Client->new;
    $client->attempts(1);
    $client->ua->inactivity_timeout($ENV{OPENQA_WORKER_CACHE_SERVICE_CHECK_INACTIVITY_TIMEOUT} // 10);
}

sub exec ($self) {
    my $return_code = $self->init;
    Mojo::IOLoop->singleton->start;
    return $return_code;
}

sub _prepare_cache_directory {
    my ($webui_host, $cachedirectory) = @_;
    die 'No cachedir' unless $cachedirectory;

    my $host_to_cache = Mojo::URL->new($webui_host)->host || $webui_host;
    my $shared_cache = File::Spec->catdir($cachedirectory, $host_to_cache);
    File::Path::make_path($shared_cache);
    log_info("CACHE: caching is enabled, setting up $shared_cache");

    # make sure the downloads are in the same file system - otherwise
    # asset->move_to becomes a bit more expensive than it should
    my $tmpdir = File::Spec->catdir($cachedirectory, 'tmp');
    File::Path::make_path($tmpdir);
    $ENV{MOJO_TMPDIR} = $tmpdir;

    return $shared_cache;
}

sub _assert_whether_job_acceptance_possible {
    my ($self) = @_;

    die 'attempt to accept a new job although there are still pending jobs' if $self->has_pending_jobs;
    die 'attempt to accept a new job although there is already a job running' if $self->current_job;
}

# brings the overall worker into a state where it can accept the next job (e.g. pool directory is cleaned up)
sub _prepare_job_execution {
    my ($self, $job, %args) = @_;

    $job->on(status_changed => sub { $self->_handle_job_status_changed(@_) });
    $job->on(
        uploading_results_concluded => sub ($event, $event_info) {
            my $upload_up_to = $event_info->{upload_up_to};
            my $module = $job->current_test_module;
            my $info = $upload_up_to ? "up to $upload_up_to" : ($module ? "at $module" : 'no current module');
            log_debug "Upload concluded ($info)";
        });

    if (!$args{only_skipping}) {
        # prepare logging
        remove_log_channel('autoinst');
        remove_log_channel('worker');
        add_log_channel('autoinst', path => 'autoinst-log.txt', level => 'debug');
        add_log_channel(
            'worker',
            path => 'worker-log.txt',
            level => $self->settings->global_settings->{LOG_LEVEL} // 'info',
            default => 'append',
        );

        # ensure the pool directory is cleaned up before starting a new job
        # note: The cleanup after finishing the last job might have been prevented via --no-cleanup.
        $self->_clean_pool_directory unless $self->no_cleanup;
    }

    delete $self->{_pending_job_ids}->{$job->id};
    $self->current_job($job);
    $self->current_webui_host($job->client->webui_host);
}

# makes a (sub) queue of pending OpenQA::Worker::Job objects from the specified $sub_sequence of job IDs
sub _enqueue_job_sub_sequence {
    my ($self, $client, $job_queue, $sub_sequence, $job_data, $job_ids) = @_;

    for my $job_id_or_sub_sequence (@$sub_sequence) {
        if (ref($job_id_or_sub_sequence) eq 'ARRAY') {
            push(@$job_queue,
                $self->_enqueue_job_sub_sequence($client, [], $job_id_or_sub_sequence, $job_data, $job_ids));
        }
        else {
            log_debug("Enqueuing job $job_id_or_sub_sequence");
            $job_ids->{$job_id_or_sub_sequence} = 1;
            push(@$job_queue, OpenQA::Worker::Job->new($self, $client, $job_data->{$job_id_or_sub_sequence}));
        }
    }
    return $job_queue;
}

# removes the first job of the specified sub queue; returns the removed job and the sub queue
sub _get_next_job {
    my ($job_queue) = @_;
    return (undef, []) unless defined $job_queue && @$job_queue;

    my $first_job_or_sub_sequence = $job_queue->[0];
    return (shift @$job_queue, $job_queue) unless ref($first_job_or_sub_sequence) eq 'ARRAY';

    my ($actually_first_job, $sub_sequence) = _get_next_job($first_job_or_sub_sequence);
    shift @$job_queue unless @$first_job_or_sub_sequence;
    return ($actually_first_job, $sub_sequence);
}

# accepts or skips the next job in the queue of pending jobs
# returns a truthy value if accepting/skipping the next job was started successfully
sub _accept_or_skip_next_job_in_queue {
    my ($self, $last_job_exit_status) = @_;

    # skip next job in the current sub queue if the last job was not successful
    my $pending_jobs = $self->{_pending_jobs};
    if (($last_job_exit_status //= '?') ne WORKER_SR_DONE) {
        my $current_sub_queue = $self->{_current_sub_queue} // $pending_jobs;
        if (scalar @$current_sub_queue > 0) {
            my ($job_to_skip) = _get_next_job($pending_jobs);
            my $job_id = $job_to_skip->id;
            if ($last_job_exit_status eq WORKER_SR_BROKEN) {
                my $current_error = $self->current_error;
                log_info("Skipping job $job_id from queue because worker is broken ($current_error)");
            }
            else {
                log_info("Skipping job $job_id from queue (parent failed with result $last_job_exit_status)");
            }
            $self->_prepare_job_execution($job_to_skip, only_skipping => 1);
            return $job_to_skip->skip;

            # note: When the job has been skipped it counts as stopped. As such _accept_or_skip_next_job_in_queue()
            #       is called from _handle_job_status_changed() again to accept/skip the next job.
        }
    }

    # accept or skip the next job
    my $next_job;
    ($next_job, $self->{_current_sub_queue}) = _get_next_job($pending_jobs);
    return undef unless $next_job;

    my $next_job_id = $next_job->id;
    $self->_prepare_job_execution($next_job);
    if ($self->{_shall_terminate} && !$self->{_finishing_off}) {
        log_info("Skipping job $next_job_id from queue (worker is terminating)");
        return $next_job->skip(WORKER_COMMAND_QUIT);
    }
    if (my $skip_reason = $self->{_jobs_to_skip}->{$next_job_id}) {
        log_info("Skipping job $next_job_id from queue (web UI sent command $skip_reason)");
        return $next_job->skip($skip_reason);
    }
    else {
        log_info("Accepting job $next_job_id from queue");
        return $next_job->accept;
    }
}

# accepts a single job from the job info received via the 'grab_job' command
sub accept_job {
    my ($self, $client, $job_info) = @_;

    $self->_assert_whether_job_acceptance_possible;
    $self->_prepare_job_execution(OpenQA::Worker::Job->new($self, $client, $job_info));
    $self->current_job->accept;
}

# enqueues multiple jobs from the job info received via the 'grab_jobs' command and accepts the first one
sub enqueue_jobs_and_accept_first {
    my ($self, $client, $job_info) = @_;

    # note: The "job queue" these functions work with is just an array containing jobs or a nested array representing
    #       a "sub queue". The "sub queues" group jobs in the execution sequence which need to be skipped altogether
    #       if one job fails.

    $self->_assert_whether_job_acceptance_possible;
    $self->{_current_sub_queue} = undef;
    $self->{_jobs_to_skip} = {};
    $self->{_pending_job_ids} = {};
    $self->_enqueue_job_sub_sequence($client, $self->{_pending_jobs},
        $job_info->{sequence}, $job_info->{data}, $self->{_pending_job_ids});
    $self->_accept_or_skip_next_job_in_queue(WORKER_SR_DONE);
}

sub _inform_webuis_before_stopping {
    my ($self, $callback) = @_;

    my $clients_by_webui_host = $self->clients_by_webui_host;
    return undef unless defined $clients_by_webui_host;
    my $outstanding_transactions = scalar keys %$clients_by_webui_host;
    for my $host (keys %$clients_by_webui_host) {
        log_debug("Informing $host that we are going offline");
        $clients_by_webui_host->{$host}->quit(
            sub {
                $callback->() if ($outstanding_transactions -= 1) <= 0;
            });
    }
    return undef;
}

# stops the current job and (if there is one) and terminates the worker
sub stop {
    my ($self, $reason) = @_;

    # take record that the worker is supposed to terminate and whether it is supposed to finish off current jobs before
    my $supposed_to_finish_off = $reason && $reason eq WORKER_SR_FINISH_OFF;
    $self->{_shall_terminate} = 1;
    $self->{_finishing_off} = $supposed_to_finish_off if !defined $self->{_finishing_off} || !$supposed_to_finish_off;

    # stop immediately if there is currently no job
    my $current_job = $self->current_job;
    return $self->_inform_webuis_before_stopping(sub { Mojo::IOLoop->stop }) unless defined $current_job;
    return undef if $self->{_finishing_off};

    # stop job directly during setup because the IO loop is blocked by isotovideo.pm during setup
    return $current_job->stop($reason) if $current_job->status eq 'setup';

    Mojo::IOLoop->next_tick(sub { $current_job->stop($reason); });
}

# stops the current job if there's one and it is running
sub stop_current_job {
    my ($self, $reason) = @_;

    if (my $current_job = $self->current_job) { $current_job->stop($reason); }
}

sub kill {
    my ($self) = @_;

    if (my $current_job = $self->current_job) { $current_job->kill; }
    Mojo::IOLoop->stop;
}

sub is_stopping {
    my ($self) = @_;

    return 1 if $self->{_shall_terminate};
    my $current_job = $self->current_job or return 0;
    return $current_job->status eq 'stopping';
}

# checks whether a qemu instance using the current pool directory is running and returns its PID if that's the case
sub is_qemu_running {
    my ($self) = @_;

    return undef unless my $pool_directory = $self->pool_directory;
    return undef unless open(my $fh, '<', my $pid_file = "$pool_directory/qemu.pid");

    my $pid = <$fh>;
    chomp($pid);
    close($fh);
    return undef unless $pid;

    my $link = readlink("/proc/$pid/exe");
    if (!$link || !($link =~ /\/qemu-[^\/]+$/)) {
        # delete the obsolete PID file (it might have been spared on cleanup if QEMU was still running)
        unlink($pid_file) unless $self->no_cleanup;
        return undef;
    }
    return undef unless $link;
    return undef unless $link =~ /\/qemu-[^\/]+$/;

    return $pid;
}

# checks whether the worker is available
# note: This is used to check certain error conditions *before* starting a job to prevent incompletes and
#       being able to propagate the brokenness to the web UIs.
sub check_availability {
    my ($self) = @_;

    # check whether the cache service is available if caching enabled
    if (my $cache_service_client = $self->{_cache_service_client}) {
        my $error = $cache_service_client->info->availability_error;
        return 'Worker cache not available: ' . $error if $error;
    }

    # check whether qemu is still running
    if (my $qemu_pid = $self->is_qemu_running) {
        return "A QEMU instance using the current pool directory is still running (PID: $qemu_pid)";
    }

    # ensure pool directory is locked
    if (my $error = $self->_setup_pool_directory) {
        return $error;
    }

    return undef;
}

sub _handle_client_status_changed {
    my ($self, $client, $event_data) = @_;

    my $status = $event_data->{status};
    my $error_message = $event_data->{error_message};
    my $webui_host = $client->webui_host;
    return log_info("Registering with openQA $webui_host") if $status eq 'registering';
    return log_info('Establishing ws connection via ' . $event_data->{url}) if $status eq 'establishing_ws';
    my $worker_id = $client->worker_id;
    return log_info("Registered and connected via websockets with openQA host $webui_host and worker ID $worker_id")
      if $status eq 'connected';
    # handle case when trying to connect to web UI should *not* be attempted again
    if ($status eq 'disabled') {
        log_error("$error_message - ignoring server");

        # shut down if there are no web UIs left and there's currently no running job
        my $clients_by_webui_host = $self->clients_by_webui_host;
        my $webui_hosts = $self->settings->webui_hosts;
        for my $host (@$webui_hosts) {
            my $client = $clients_by_webui_host->{$host};
            if ($client && $client->status ne 'disabled') {
                return undef;
            }
        }
        if (!defined $self->current_job) {
            log_error('Stopping because registration with all configured web UI hosts failed');
            return Mojo::IOLoop->stop;
        }

        # continue executing the current job even though the registration is not possible anymore; it
        # will fail on its own anyways due to the API errors (which then will be passed to the web UI
        # as usual if that's possible)
        log_error('Stopping after the current job because registration with all configured web UI hosts failed');
        $self->{_shall_terminate} = 1;
    }
    # handle failures where it makes sense to reconnect
    elsif ($status eq 'failed') {
        my $interval = $ENV{OPENQA_WORKER_CONNECT_INTERVAL} // 10;
        log_warning("$error_message - trying again in $interval seconds");
        Mojo::IOLoop->timer($interval => sub { $client->register() });
    }
    return undef;
}

sub _handle_job_status_changed {
    my ($self, $job, $event_data) = @_;

    my $job_id = $job->id // '?';
    my $job_name = $job->name // '?';
    my $client = $job->client;
    my $webui_host = $client->webui_host;
    my $status = $event_data->{status};
    my $reason = $event_data->{reason};
    my $current_job = $self->current_job;
    if (!$current_job || $job != $current_job) {
        die "Received job status update for job $job_id ($status) which is not the current one.";
    }

    if ($status eq 'accepting') {
        log_debug("Accepting job $job_id from $webui_host.");
    }
    elsif ($status eq 'accepted') {
        $job->start();
    }
    elsif ($status eq 'setup') {
        log_debug("Setting job $job_id from $webui_host up");
    }
    elsif ($status eq 'running') {
        log_debug("Running job $job_id from $webui_host: $job_name.");
    }
    elsif ($status eq 'stopping') {
        log_debug("Stopping job $job_id from $webui_host: $job_name - reason: $reason");
    }
    elsif ($status eq 'stopped') {
        if (my $error_message = $event_data->{error_message}) {
            log_error($error_message);
        }
        log_debug("Job $job_id from $webui_host finished - reason: $reason");
        $self->current_job(undef);
        $self->current_webui_host(undef);

        # handle case when the worker should not continue to run e.g. because the user stopped it or
        # a critical error occurred
        if ($self->{_shall_terminate}) {
            return $self->stop(WORKER_COMMAND_QUIT) unless $self->has_pending_jobs;

            # ensure we actually skip the next jobs in the queue if user stops the worker with Ctrl+C right
            # after the last job has concluded
            $reason = 'worker terminates' if $reason eq WORKER_SR_DONE && !$self->{_finishing_off};
        }

        unless ($self->no_cleanup) {
            log_debug('Cleaning up for next job');
            $self->_clean_pool_directory;
        }

        # update the general worker availability (e.g. we might detect here that QEMU from the last run
        # hasn't been terminated yet)
        # incomplete subsequent jobs in the queue if it turns out the worker is generally broken
        # continue with the next job in the queue (this just returns if there are no further jobs)
        $self->current_error(my $availability_error = $self->check_availability);
        log_warning $availability_error if $availability_error;
        if (!$self->_accept_or_skip_next_job_in_queue($availability_error ? WORKER_SR_BROKEN : $reason)) {
            # stop if we can not accept/skip the next job (e.g. because there's no further job) if that's configured
            $self->stop(WORKER_COMMAND_QUIT) if $self->settings->global_settings->{TERMINATE_AFTER_JOBS_DONE};
        }
    }
    # FIXME: Avoid so much elsif like in CommandHandler.pm.
}

sub _setup_pool_directory {
    my ($self) = @_;

    # skip if we have already locked the pool directory
    return undef if defined $self->{_pool_directory_lock_fd};

    my $pool_directory = $self->pool_directory;
    return 'No pool directory assigned.' unless $pool_directory;

    eval { $self->{_pool_directory_lock_fd} = $self->_lock_pool_directory };
    return 'Unable to lock pool directory: ' . $@ if $@;
    return undef;
}

sub _lock_pool_directory {
    my ($self) = @_;

    die 'no pool directory assigned' unless my $pool_directory = $self->pool_directory;
    make_path($pool_directory) unless -e $pool_directory;

    chdir $pool_directory || die "cannot change directory to $pool_directory: $!\n";
    open(my $lockfd, '>>', '.locked') or die "cannot open lock file in $pool_directory: $!\n";
    unless (fcntl($lockfd, F_SETLK, pack('ssqql', F_WRLCK, 0, 0, 0, $$))) {
        die "$pool_directory already locked\n";
    }
    $lockfd->autoflush(1);
    truncate($lockfd, 0);
    print $lockfd "$$\n";
    return $lockfd;
}

sub _clean_pool_directory {
    my ($self) = @_;

    return undef unless my $pool_directory = $self->pool_directory;

    # prevent cleanup of "qemu.pid" file if QEMU is still running so is_qemu_running() continues to work
    my %excludes;
    $excludes{"$pool_directory/qemu.pid"} = 1 if $self->is_qemu_running;
    $excludes{"$pool_directory/worker_packages.txt"} = 1;

    for my $file (glob "$pool_directory/*") {
        next if $excludes{$file};
        if (-d $file) {
            remove_tree($file);
        }
        else {
            unlink($file);
        }
    }
}

sub has_pending_jobs {
    my ($self) = @_;

    return scalar @{$self->{_pending_jobs}} > 0;
}

sub pending_job_ids {
    my ($self) = @_;

    return [sort keys %{$self->{_pending_job_ids}}];
}

sub _find_job_in_queue {
    my ($job_id, $queue) = @_;

    for my $job_or_sub_sequence (@$queue) {
        if (ref($job_or_sub_sequence) eq 'ARRAY') {
            return _find_job_in_queue($job_id, $job_or_sub_sequence);
        }
        elsif ($job_or_sub_sequence->id eq $job_id) {
            return $job_or_sub_sequence;
        }
    }
    return undef;
}

sub find_current_or_pending_job {
    my ($self, $job_id) = @_;

    if (my $current_job = $self->current_job) {
        return $current_job if $current_job->id eq $job_id;
    }
    return _find_job_in_queue($job_id, $self->{_pending_jobs});
}

sub current_job_ids {
    my ($self) = @_;

    my @current_job_ids;
    if (my $current_job = $self->current_job) {
        push(@current_job_ids, $current_job->id);
    }
    push(@current_job_ids, @{$self->pending_job_ids});
    return \@current_job_ids;
}

sub is_busy {
    my ($self) = @_;
    return 1 if $self->current_job;
    return 1 if $self->has_pending_jobs;
    return 0;
}

# marks a job to be immediately skipped when picking it from the queue
sub skip_job {
    my ($self, $job_id, $reason) = @_;

    $self->{_jobs_to_skip}->{$job_id} = $reason;
}

sub handle_signal {
    my ($self, $signal) = @_;

    log_info("Received signal $signal");
    return $self->stop(WORKER_SR_FINISH_OFF) if $signal eq 'HUP';
    return $self->stop(WORKER_COMMAND_QUIT);
}

1;
