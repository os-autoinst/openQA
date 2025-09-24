# Copyright 2015-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Worker;
use Mojo::Base -base, -signatures;
use IPC::Run ();

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

use Fcntl;
use Feature::Compat::Try;
use File::Path qw(make_path remove_tree);
use File::Spec::Functions 'catdir';
use List::Util qw(all max min);
use Mojo::IOLoop;
use Mojo::File 'path';
use POSIX;
use Scalar::Util 'looks_like_number';
use OpenQA::Constants
  qw(WEBSOCKET_API_VERSION WORKER_COMMAND_QUIT WORKER_SR_BROKEN WORKER_SR_DONE WORKER_SR_DIED WORKER_SR_FINISH_OFF);
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
has 'current_error_is_fatal';
has 'worker_hostname';
has 'isotovideo_interface_version';

sub encode_token ($entry_string) { OpenQA::Worker::Settings::encode_token(split /@/, $entry_string) }

sub new ($class, $cli_options) {
    # determine instance number
    my $instance_number = $cli_options->{instance};
    die 'no instance number specified' unless defined $instance_number;
    die "the specified instance number \"$instance_number\" is no number" unless looks_like_number($instance_number);

    # determine settings and create app
    my $settings = OpenQA::Worker::Settings->new($instance_number, $cli_options);
    my $short_hostname = (POSIX::uname)[1];
    my $app = OpenQA::Worker::App->new(
        mode => 'production',
        log_name => 'worker',
        instance => $instance_number,
    );
    $settings->auto_detect_worker_address($short_hostname);
    $settings->apply_to_app($app);

    # setup the isotovideo engine
    my $isotovideo_interface_version = OpenQA::Worker::Engines::isotovideo::set_engine_exec($cli_options->{isotovideo});

    my $self = $class->SUPER::new(
        instance_number => $instance_number,
        no_cleanup => $cli_options->{'no-cleanup'},
        pool_directory => prjdir() . "/pool/$instance_number",
        app => $app,
        settings => $settings,
        clients_by_webui_host => undef,
        worker_hostname => $short_hostname,
        isotovideo_interface_version => $isotovideo_interface_version,
    );
    $self->{_cli_options} = $cli_options;
    $self->{_pool_directory_lock_fd} = undef;
    $self->{_shall_terminate} = 0;
    $self->{_finishing_off} = undef;
    $self->{_ovs_dbus_service_name} = $ENV{OVS_DBUS_SERVICE_NAME} // 'org.opensuse.os_autoinst.switch';

    return $self;
}

# logs the basic configuration of the worker instance
sub log_setup_info ($self) {
    my $instance = $self->instance_number;
    my $settings = $self->settings;
    my $global_settings = $settings->global_settings;
    my $msg = "worker $instance:";
    $msg .= "\n - config file:                      " . ($settings->file_path // 'not found');
    $msg .= "\n - name used to register:            " . ($self->worker_hostname // 'undetermined');
    $msg .= "\n - worker address (WORKER_HOSTNAME): " . ($global_settings->{WORKER_HOSTNAME} // 'undetermined');
    $msg .= "\n - isotovideo version:               " . $self->isotovideo_interface_version;
    $msg .= "\n - websocket API version:            " . WEBSOCKET_API_VERSION;
    $msg .= "\n - web UI hosts:                     " . join(',', @{$settings->webui_hosts});
    $msg .= "\n - class:                            " . ($global_settings->{WORKER_CLASS} // '?');
    $msg .= "\n - no cleanup:                       " . ($self->no_cleanup ? 'yes' : 'no');
    $msg .= "\n - pool directory:                   " . $self->pool_directory;
    log_info($msg);

    my $parse_errors = $settings->parse_errors;
    log_error(join("\n - ", 'Errors occurred when reading config file:', @$parse_errors)) if (@$parse_errors);

    return $msg;
}

# determines the worker's capabilities
sub capabilities ($self) {
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
        open(my $LSCPU, '-|', 'LC_ALL=C lscpu');
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
    open(my $MEMINFO, '<', '/proc/meminfo');
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
    $caps->{parallel_one_host_only} = $global_settings->{PARALLEL_ONE_HOST_ONLY};
    return $self->{_caps} = $caps;
}

sub status ($self) {
    my %status = (type => 'worker_status');
    if (my $current_job = $self->current_job) {
        $status{status} = 'working';
        $status{current_webui_host} = $self->current_webui_host;
        $status{job} = $current_job->info;
    }
    elsif (my $availability_reason = $self->set_current_error_based_on_availability) {
        $status{status} = 'broken';
        $status{reason} = $availability_reason;
    }
    else {
        $status{status} = 'free';
    }
    if (my $queue = $self->{_queue}) {
        $status{pending_job_ids} = $queue->{pending_job_ids} if keys %{$queue->{pending_job_ids}};
    }
    return \%status;
}

# Store the packages list of the environment the worker runs in
sub _store_package_list ($self, $cmd = undef) {
    return undef unless $cmd;
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
    return undef;
}

# initializes the worker so it does its thing when the Mojo::IOLoop is started
# note: Do not change the settings - especially the web UI hosts after calling this function.
sub init ($self) {
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
    $self->set_current_error_based_on_availability;
    log_error 'Unavailable: ' . $self->current_error if $self->current_error;

    # register error handler to stop the current job when a critical/unhandled error occurs
    Mojo::IOLoop->singleton->reactor->on(
        error => sub ($reactor, $err) {
            my $fatal_error = 'Another error occurred when trying to stop gracefully due to an error';
            $return_code = 1;

            # avoid getting stuck waiting on result upload
            my $is_stopping = $self->is_stopping;
            if (my $job = $self->current_job) { $job->conclude_upload_if_ongoing }

            # try to stop gracefully unless we are already stopping
            if (!$is_stopping && (!$self->{_shall_terminate} || $self->{_finishing_off})) {
                try {
                    log_error('Stopping because a critical error occurred.');
                    return $self->stop('exception');    # try to stop the job nicely
                }
                catch ($e) { $fatal_error = "$fatal_error: $e" }
            }

            # kill if stopping gracefully does not work
            chomp $fatal_error;
            log_error($fatal_error);
            log_error('Trying to kill ourself forcefully now');
            $self->kill;
        });


    my $global_settings = $settings->global_settings;
    my $webui_host_specific_settings = $settings->webui_host_specific_settings;

    return 1 if $self->_store_package_list($global_settings->{PACKAGES_CMD});

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

    my $interval = $global_settings->{IPMI_AUTOSHUTDOWN_INTERVAL} // 300;
    if (   $global_settings->{IPMI_HOSTNAME}
        && $global_settings->{IPMI_USER}
        && $global_settings->{IPMI_PASSWORD}
        && $interval ne '0')
    {
        log_info 'IPMI config present -> will periodically make sure SUT is powered off when unused.';
        Mojo::IOLoop->recurring($interval => sub { $self->shutdown_ipmi_sut() });
    }

    return \$return_code;
}

sub shutdown_ipmi_sut ($self) {
    return if $self->current_job;
    my $sgs = $self->settings->global_settings;
    my $ipmi_host = $sgs->{IPMI_HOSTNAME};
    my $ipmi_user = $sgs->{IPMI_USER};
    my $ipmi_pass = $sgs->{IPMI_PASSWORD};
    my $ipmi_opts = $sgs->{IPMI_OPTIONS} // '-I lanplus';
    my @cmd = (
        'ipmitool', split(' ', $ipmi_opts),
        '-H', $ipmi_host, '-U', $ipmi_user, '-P', $ipmi_pass, 'chassis', 'power', 'off'
    );
    my $ret = IPC::Run::run(\@cmd, \my $stdin, \my $stdout, \my $stderr);
    chomp $stderr;
    log_warning(join(' ', map { $_ eq $ipmi_pass ? '[masked]' : $_ } @cmd) . ": $stderr") unless $ret;
}

sub configure_cache_client ($self) {
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
    return $$return_code;
}

sub _prepare_cache_directory ($webui_host, $cachedirectory) {
    my $host_to_cache = Mojo::URL->new($webui_host)->host || $webui_host;
    return File::Spec->catdir($cachedirectory, $host_to_cache);
}

sub _assert_whether_job_acceptance_possible ($self) {
    die 'attempt to accept a new job although there are still pending jobs' if $self->has_pending_jobs;
    die 'attempt to accept a new job although there is already a job running' if $self->current_job;
}

# brings the overall worker into a state where it can accept the next job (e.g. pool directory is cleaned up)
sub _prepare_job_execution ($self, $job, %args) {
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

    delete $self->{_queue}->{pending_job_ids}->{$job->id} if $self->{_queue};
    $self->current_job($job);
    $self->current_webui_host($job->client->webui_host);
}

sub _prepare_and_skip_job ($self, $job_to_skip, $skip_reason = undef) {
    $self->_prepare_job_execution($job_to_skip, only_skipping => 1);
    $job_to_skip->skip($skip_reason);
}

# makes a (sub) queue of pending OpenQA::Worker::Job objects from the specified $sub_sequence of job IDs
sub _enqueue_job_sub_sequence ($self, $client, $job_queue, $sub_sequence, $job_data) {

    for my $job_id_or_sub_sequence (@$sub_sequence) {
        if (ref($job_id_or_sub_sequence) eq 'ARRAY') {
            push(@$job_queue, $self->_enqueue_job_sub_sequence($client, [], $job_id_or_sub_sequence, $job_data));
        }
        else {
            log_debug("Enqueuing job $job_id_or_sub_sequence");
            $self->{_queue}->{pending_job_ids}->{$job_id_or_sub_sequence} = 1;
            push(@$job_queue, OpenQA::Worker::Job->new($self, $client, $job_data->{$job_id_or_sub_sequence}));
        }
    }
    return $job_queue;
}

# removes the first job of $job_queue updating $queue_info; returns the removed job
# note: Have a look at subtest 'get next job in queue' in 24-worker-overall.t to see how this function is
#       called and how it processes the specified $job_queue. Also see the subtests 'simple tree/chain …'
#       in 05-scheduler-serialize-directly-chained-dependencies.t for simple examples showing what kind
#       of array structure is passed as $job_queue for certain dependency trees.
sub _grab_next_job ($job_queue, $queue_info, $depth = 0) {
    # pop elements from parent chain when going up the chain
    my $parent_chain = $queue_info->{parent_chain};
    if (my $end_of_chain = $queue_info->{end_of_chain}) {
        pop @$parent_chain while $end_of_chain--;
        $queue_info->{end_of_chain} = 0;
    }

    # handle case of empty $job_queue
    return undef unless defined $job_queue && @$job_queue;

    # handle case when we've found the next job
    my $first_job_or_sub_sequence = $job_queue->[0];
    if (ref $first_job_or_sub_sequence ne 'ARRAY') {
        my $first_job = shift @$job_queue;
        push @$parent_chain, $first_job if $depth == @$parent_chain;
        return $first_job;
    }

    # handle case when we've hit another level of nesting
    my $first_job = _grab_next_job($first_job_or_sub_sequence, $queue_info, $depth + 1);
    unless (@$first_job_or_sub_sequence) {
        shift @$job_queue;
        ++$queue_info->{end_of_chain};
    }
    return $first_job;
}

# accepts or skips the next job in the queue of pending jobs
# returns a truthy value if accepting/skipping the next job was started successfully
sub _accept_or_skip_next_job_in_queue ($self) {
    # grab the next job from the queue
    my $queue_info = $self->{_queue};
    return undef unless my $next_job = _grab_next_job($queue_info->{pending_jobs}, $queue_info);

    # skip the job if there's a general reason or if the directly chained parent failed
    my $next_job_id = $next_job->id;
    if ($self->{_shall_terminate} && !$self->{_finishing_off}) {
        log_info("Skipping job $next_job_id from queue (worker is terminating)");
        return $self->_prepare_and_skip_job($next_job, WORKER_COMMAND_QUIT);
    }
    if (my $skip_reason = $queue_info->{jobs_to_skip}->{$next_job_id}) {
        log_info("Skipping job $next_job_id from queue (web UI sent command $skip_reason)");
        return $self->_prepare_and_skip_job($next_job, $skip_reason);
    }
    if (my $e = $self->current_error) {
        if ($self->current_error_is_fatal) {
            log_info "Skipping job $next_job_id from queue because worker is broken ($e)";
            return $self->_prepare_and_skip_job($next_job);
        }
        else {
            log_info "Continuing with job $next_job_id as it is already enqueued despite current error ($e)";
        }
    }
    my $parent_chain = $queue_info->{parent_chain};
    my $last_parent = $parent_chain->[-1];
    my $relevant_parent = $last_parent && $last_parent->id != $next_job_id ? $last_parent : $parent_chain->[-2];
    if ($relevant_parent) {
        if (my $parent_reason = $queue_info->{failed_jobs}->{$relevant_parent->id}) {
            log_info("Skipping job $next_job_id from queue (parent failed with $parent_reason)");
            return $self->_prepare_and_skip_job($next_job);
        }
    }

    # accept the job otherwise
    log_info("Accepting job $next_job_id from queue");
    $self->_prepare_job_execution($next_job);
    return $next_job->accept;
}

# accepts a single job from the job info received via the 'grab_job' command
sub accept_job ($self, $client, $job_info) {
    $self->_assert_whether_job_acceptance_possible;
    $self->{_queue} = undef;
    $self->_prepare_job_execution(OpenQA::Worker::Job->new($self, $client, $job_info));
    $self->current_job->accept;
}

# initializes a new job queue (empty by default)
sub _init_queue ($self, $pending_jobs = []) {
    $self->{_queue} = {
        pending_jobs => $pending_jobs,
        pending_job_ids => {},
        jobs_to_skip => {},
        failed_jobs => {},
        parent_chain => [],
        end_of_chain => 0,
    };
    return $pending_jobs;
}

# enqueues multiple jobs from the job info received via the 'grab_jobs' command and accepts the first one
sub enqueue_jobs_and_accept_first ($self, $client, $job_info) {
    # note: The "job queue" these functions work with is just an array containing jobs or a nested array representing
    #       a "sub queue". The "sub queues" group jobs in the execution sequence which need to be skipped altogether
    #       if one job fails.

    $self->_assert_whether_job_acceptance_possible;
    $self->_enqueue_job_sub_sequence($client, $self->_init_queue, $job_info->{sequence}, $job_info->{data});
    $self->_accept_or_skip_next_job_in_queue;
}

sub _inform_webuis_before_stopping ($self, $callback) {
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
sub stop ($self, $reason = undef) {
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
sub stop_current_job ($self, $reason = undef) {
    if (my $current_job = $self->current_job) { $current_job->stop($reason) }
}

sub kill ($self) {
    if (my $current_job = $self->current_job) { $current_job->kill }
    Mojo::IOLoop->stop;
}

sub is_stopping ($self) {
    return 1 if $self->{_shall_terminate};
    my $current_job = $self->current_job or return 0;
    return $current_job->status eq 'stopping';
}

sub is_qemu ($executable_path) { defined $executable_path && $executable_path =~ m{/qemu-[^/]+$} }

# checks whether a qemu instance using the current pool directory is running and returns its PID if that's the case
sub is_qemu_running ($self) {
    return undef unless my $pool_directory = $self->pool_directory;
    return undef unless open(my $fh, '<', my $pid_file = "$pool_directory/qemu.pid");

    my $pid = <$fh>;
    chomp($pid);
    close($fh);
    return undef unless $pid;

    return $pid if is_qemu(readlink("/proc/$pid/exe"));

    # delete the obsolete PID file (it might have been spared on cleanup if QEMU was still running)
    unlink($pid_file) unless $self->no_cleanup;
    return undef;
}

sub is_ovs_dbus_service_running ($self) {
    try { defined &Net::DBus::system or require Net::DBus }
    catch ($e) { return 0 }
    unless (defined $self->{_system_dbus}) {
        $self->{_system_dbus} = Net::DBus->system(nomainloop => 1);
        # this avoids piling up signals we never do anything with - POO #183833
        $self->{_system_dbus}->get_bus_object->disconnect_from_signal('NameOwnerChanged', 1);
    }
    try { return defined $self->{_system_dbus}->get_service('org.opensuse.os_autoinst.switch') }
    catch ($e) { return 0 }
}

# returns whether the worker is available and a reason
# note: This is used to check certain error conditions *before* starting a job to prevent incompletes and
#       being able to propagate the brokenness to the web UIs.
# note: High load will yield a corresponding error message as reason so the worker becomes broken and
#       thus will not pick up any new jobs. However, a worker under high load is still considered being
#       able to work on jobs that are already enqueued. Hence this function returns a "1" for the
#       availability in this case.
sub check_availability ($self) {
    # check whether the cache service is available if caching enabled
    if (my $cache_service_client = $self->{_cache_service_client}) {
        my $error = $cache_service_client->info->availability_error;
        my $host = $cache_service_client->host // '?';
        return (0, "Worker cache not available via $host: $error") if $error;
    }

    # check whether qemu is still running
    if (my $qemu_pid = $self->is_qemu_running) {
        return (0, "A QEMU instance using the current pool directory is still running (PID: $qemu_pid)");
    }

    # ensure pool directory is locked
    if (my $error = $self->_setup_pool_directory) { return (0, $error) }

    # auto-detect worker address if not specified explicitly
    my $settings = $self->settings;
    return (0, 'Unable to determine worker address (WORKER_HOSTNAME)') unless $settings->auto_detect_worker_address;

    # check org.opensuse.os_autoinst.switch if it is a MM-capable worker slot
    return (0, "D-Bus service '$self->{_ovs_dbus_service_name}' is not running")
      if $settings->has_class('tap') && !$self->is_ovs_dbus_service_running;

    # continue with enqueued jobs in any case but avoid picking up new jobs if system utilization is critical
    return (1, $self->_check_system_utilization);
}

sub set_current_error_based_on_availability ($self) {
    my ($is_available, $reason) = $self->check_availability;
    $self->current_error($reason);
    $self->current_error_is_fatal(!$is_available);
    return $reason;
}

sub _handle_client_status_changed ($self, $client, $event_data) {
    my $status = $event_data->{status};
    my $error_message = $event_data->{error_message} // $event_data->{ws_error_message};
    my $webui_host = $client->webui_host;
    return log_info("Registering with openQA $webui_host") if $status eq 'registering';
    return log_info('Establishing ws connection via ' . $event_data->{url}) if $status eq 'establishing_ws';
    my $worker_id = $client->worker_id;
    if ($status eq 'connected') {
        log_info("Registered and connected via websockets with openQA host $webui_host and worker ID $worker_id");
        my $current_job = $self->current_job;
        return undef unless $current_job && $current_job->is_supposed_to_start;
        log_info('Trying to accept current job ' . $current_job->id . ' again');
        $current_job->accept;
    }
    elsif ($status eq 'disabled') {
        # handle case when trying to connect to web UI should *not* be attempted again
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
        my $interval = $event_data->{retry_after} // $ENV{OPENQA_WORKER_CONNECT_INTERVAL} // 10;
        log_warning("$error_message - trying again in $interval seconds");
        Mojo::IOLoop->timer($interval => sub { $client->register() });
        # stop current job if not accepted yet but out of acceptance attempts
        if (my $current_job = $self->current_job) { $current_job->stop_if_out_of_acceptance_attempts }
    }
    return undef;
}

sub _handle_job_status_changed ($self, $job, $event_data) {
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
        log_debug("Job $job_id from $webui_host finished - reason: $reason");
        if (my $error_message = $event_data->{error_message}) { log_error($error_message) }
        $self->current_job(undef);
        $self->current_webui_host(undef);
        if (my $queue = $self->{_queue}) {
            $queue->{failed_jobs}->{$job_id} = $reason if $reason ne WORKER_SR_DONE || !$event_data->{ok};
        }

        # handle case when the worker should not continue to run e.g. because the user stopped it or
        # a critical error occurred
        return $self->stop(WORKER_COMMAND_QUIT) if $self->{_shall_terminate} && !$self->has_pending_jobs;

        unless ($self->no_cleanup) {
            log_debug('Cleaning up for next job');
            $self->_clean_pool_directory;
        }

        # update the general worker availability (e.g. we might detect here that QEMU from the last run
        # hasn't been terminated yet)
        # incomplete subsequent jobs in the queue if it turns out the worker is generally broken
        # continue with the next job in the queue (this just returns if there are no further jobs)
        my $availability_reason = $self->set_current_error_based_on_availability;
        log_warning $availability_reason if $availability_reason;

        if (!$self->_accept_or_skip_next_job_in_queue) {
            # stop if we can not accept/skip the next job (e.g. because there's no further job) if that's configured
            $self->stop(WORKER_COMMAND_QUIT) if $self->settings->global_settings->{TERMINATE_AFTER_JOBS_DONE};
        }
    }
}

sub _load_avg ($path = $ENV{OPENQA_LOAD_AVG_FILE} // '/proc/loadavg') {
    my @load;
    try {
        @load = split(' ', path($path)->slurp);
        splice @load, 3;    # remove non-load numbers
        log_error "Unable to parse system load from file '$path'" and return []
          unless all { looks_like_number $_ } @load;
    }
    catch ($e) { log_warning "Unable to determine average load: $e" }
    return \@load;
}

sub _check_system_utilization (
    $self,
    $threshold = $self->settings->global_settings->{CRITICAL_LOAD_AVG_THRESHOLD},
    $load = _load_avg())
{
    return undef unless $threshold && @$load >= 3;
    # look at the load evolution over time to react quick enough if the load
    # rises but accept a falling edge
    return
"The average load (@$load) is exceeding the configured threshold of $threshold. The worker will temporarily not accept new jobs until the load is lower again."
      if max(@$load) > $threshold && ($load->[0] > $load->[1] || $load->[0] > $load->[2] || min(@$load) > $threshold);
    return undef;
}

sub _setup_pool_directory ($self) {
    # skip if we have already locked the pool directory
    return undef if defined $self->{_pool_directory_lock_fd};

    my $pool_directory = $self->pool_directory;
    return 'No pool directory assigned.' unless $pool_directory;

    try { $self->{_pool_directory_lock_fd} = $self->_lock_pool_directory }
    catch ($e) { return 'Unable to lock pool directory: ' . $e }
    return undef;
}

sub _lock_pool_directory ($self) {
    die 'no pool directory assigned' unless my $pool_directory = $self->pool_directory;
    make_path($pool_directory) unless -e $pool_directory;

    chdir $pool_directory || die "cannot change directory to $pool_directory: $!\n";
    open(my $lockfd, '>>', '.locked') or die "cannot open lock file in $pool_directory: $!\n";
    die "$pool_directory already locked\n" unless fcntl $lockfd, F_SETLK, pack('ssqql', F_WRLCK, 0, 0, 0, $$);
    $lockfd->autoflush(1);
    truncate($lockfd, 0);
    print $lockfd "$$\n";
    return $lockfd;
}

sub _clean_pool_directory ($self) {
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

sub is_executing_single_job ($self) { !$self->{_queue} }

sub has_pending_jobs ($self) { $self->{_queue} && scalar @{$self->{_queue}->{pending_jobs}} > 0 }

sub pending_job_ids ($self) { $self->{_queue} ? [sort keys %{$self->{_queue}->{pending_job_ids}}] : [] }

sub _find_job_in_queue ($job_id, $queue) {
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

sub find_current_or_pending_job ($self, $job_id) {
    if (my $current_job = $self->current_job) {
        return $current_job if $current_job->id eq $job_id;
    }
    if (my $queue = $self->{_queue}) {
        return _find_job_in_queue($job_id, $queue->{pending_jobs});
    }
}

sub current_job_ids ($self) {
    my @current_job_ids;
    if (my $current_job = $self->current_job) {
        push(@current_job_ids, $current_job->id);
    }
    push(@current_job_ids, @{$self->pending_job_ids});
    return \@current_job_ids;
}

sub is_busy ($self) { defined $self->current_job || $self->has_pending_jobs }

# marks a job to be immediately skipped when picking it from the queue
sub skip_job ($self, $job_id, $reason) {
    if (my $queue = $self->{_queue}) { $queue->{jobs_to_skip}->{$job_id} = $reason }
}

sub handle_signal ($self, $signal) {
    log_info("Received signal $signal");
    return $self->stop(WORKER_SR_FINISH_OFF) if $signal eq 'HUP';
    return $self->stop(WORKER_COMMAND_QUIT);
}

1;
