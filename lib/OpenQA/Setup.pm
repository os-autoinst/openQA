# Copyright 2017-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Setup;
use Mojo::Base -strict, -signatures;

use Mojo::File 'path';
use Mojo::Util 'trim';
use Mojo::Loader 'load_class';
use Config::IniFiles;
use OpenQA::App;
use OpenQA::Log 'log_format_callback';
use OpenQA::Utils qw(:DEFAULT assetdir random_string);
use File::Path 'make_path';
use POSIX 'strftime';
use Time::HiRes 'gettimeofday';
use Time::Seconds;
use Scalar::Util 'looks_like_number';
use OpenQA::Constants qw(DEFAULT_WORKER_TIMEOUT MAX_TIMER);
use OpenQA::JobGroupDefaults;
use OpenQA::Jobs::Constants qw(OK_RESULTS);
use OpenQA::Task::Job::Limit;

my %CARRY_OVER_DEFAULTS = (lookup_depth => 10, state_changes_limit => 3);
sub carry_over_defaults () { \%CARRY_OVER_DEFAULTS }

sub read_config ($app) {
    my %defaults = (
        global => {
            appname => 'openQA',
            base_url => undef,
            branding => 'openSUSE',
            download_domains => undef,
            suse_mirror => undef,
            scm => undef,
            hsts => 365,
            audit_enabled => 1,
            max_rss_limit => 0,
            profiling_enabled => 0,
            monitoring_enabled => 0,
            plugins => undef,
            hide_asset_types => 'repo',
            recognized_referers => '',
            changelog_file => '/usr/share/openqa/public/Changelog',
            job_investigate_ignore => '"(JOBTOKEN|NAME)"',
            job_investigate_git_log_limit => 200,
            job_investigate_git_timeout => 20,
            worker_timeout => DEFAULT_WORKER_TIMEOUT,
            search_results_limit => 50000,
            auto_clone_regex =>
'^(cache failure: |terminated prematurely: |api failure: Failed to register .* 503|backend died: .*VNC.*(timeout|timed out|refused)|QEMU terminated: Failed to allocate KVM HPT of order 25.* Cannot allocate memory)',
            auto_clone_limit => 20,
            force_result_regex => '',
            parallel_children_collapsable_results => join(' ', OK_RESULTS),
            service_port_delta => $ENV{OPENQA_SERVICE_PORT_DELTA} // 2,
            access_control_allow_origin_header => undef,
            api_hmac_time_tolerance => 300,
        },
        rate_limits => {
            search => 5,
        },
        auth => {
            method => 'OpenID',
            require_for_assets => 0,
        },
        'scm git' => {
            update_remote => '',
            update_branch => '',
            do_push => 'no',
            do_cleanup => 'no',
            git_auto_clone => 'yes',
            git_auto_update => 'no',
            git_auto_update_method => 'best-effort',
            checkout_needles_sha => 'no',
        },
        scheduler => {
            max_job_scheduled_time => 7,
            max_running_jobs => -1,
        },
        logging => {
            level => undef,
            file => undef,
            sql_debug => undef,
        },
        openid => {
            provider => 'https://www.opensuse.org/openid/user/',
            httpsonly => 1,
        },
        oauth2 => {
            provider => '',
            key => '',
            secret => '',
            authorize_url => '',
            token_url => '',
            user_url => '',
            token_scope => '',
            token_label => '',
            nickname_from => '',
            unique_name => '',
        },
        hypnotoad => {
            listen => ['http://localhost:9526/'],
            proxy => 1,
        },
        audit => {
            # backward-compatible name definition
            blacklist => '',
            blocklist => '',
        },
        'audit/storage_duration' => {
            startup => undef,
            jobgroup => undef,
            jobtemplate => undef,
            table => undef,
            iso => undef,
            user => undef,
            asset => undef,
            needle => undef,
            other => undef,
        },
        plugin_links => {
            operator => {},
            admin => {}
        },
        amqp => {
            reconnect_timeout => 5,
            publish_attempts => 10,
            publish_retry_delay => 1,
            publish_retry_delay_factor => 1.75,
            url => 'amqp://guest:guest@localhost:5672/',
            exchange => 'pubsub',
            topic_prefix => 'suse',
            cacertfile => '',
            certfile => '',
            keyfile => ''
        },
        obs_rsync => {
            home => '',
            retry_interval => 60,
            retry_max_count => 1400,
            queue_limit => 200,
            concurrency => 2,
            project_status_url => '',
            username => '',
            ssh_key_file => ''
        },
        cleanup => {
            concurrent => 0,
        },
        default_group_limits => {
            asset_size_limit => OpenQA::JobGroupDefaults::SIZE_LIMIT_GB,
            log_storage_duration => OpenQA::JobGroupDefaults::KEEP_LOGS_IN_DAYS,
            important_log_storage_duration => OpenQA::JobGroupDefaults::KEEP_IMPORTANT_LOGS_IN_DAYS,
            result_storage_duration => OpenQA::JobGroupDefaults::KEEP_RESULTS_IN_DAYS,
            important_result_storage_duration => OpenQA::JobGroupDefaults::KEEP_IMPORTANT_RESULTS_IN_DAYS,
        },
        no_group_limits => {
            log_storage_duration => OpenQA::JobGroupDefaults::KEEP_LOGS_IN_DAYS,
            important_log_storage_duration => OpenQA::JobGroupDefaults::KEEP_IMPORTANT_LOGS_IN_DAYS,
            result_storage_duration => OpenQA::JobGroupDefaults::KEEP_RESULTS_IN_DAYS,
            important_result_storage_duration => OpenQA::JobGroupDefaults::KEEP_IMPORTANT_RESULTS_IN_DAYS,
        },
        minion_task_triggers => {
            on_job_done => '',
        },
        misc_limits => {
            untracked_assets_storage_duration => 14,
            result_cleanup_max_free_percentage => 100,
            asset_cleanup_max_free_percentage => 100,
            screenshot_cleanup_batch_size => OpenQA::Task::Job::Limit::DEFAULT_SCREENSHOTS_PER_BATCH,
            screenshot_cleanup_batches_per_minion_job => OpenQA::Task::Job::Limit::DEFAULT_BATCHES_PER_MINION_JOB,
            results_min_free_disk_space_percentage => undef,
            minion_job_max_age => ONE_WEEK,
            generic_default_limit => 10000,
            generic_max_limit => 100000,
            tests_overview_max_jobs => 2000,
            all_tests_default_finished_jobs => 500,
            all_tests_max_finished_jobs => 5000,
            list_templates_default_limit => 5000,
            list_templates_max_limit => 20000,
            next_jobs_default_limit => 500,
            next_jobs_max_limit => 10000,
            previous_jobs_default_limit => 500,
            previous_jobs_max_limit => 10000,
            job_settings_max_recent_jobs => 20000,
            assets_default_limit => 100000,
            assets_max_limit => 200000,
            max_online_workers => 1000,
            worker_limit_retry_delay => ONE_HOUR / 4,
        },
        archiving => {
            archive_preserved_important_jobs => 0,
        },
        job_settings_ui => {
            keys_to_render_as_links => '',
            default_data_dir => 'data',
        },
        'assets/storage_duration' => {
            # intentionally left blank for overview
        },
        secrets => {github_token => ''},
        # allow dynamic config keys based on job results
        hooks => {},
        influxdb => {
            ignored_failed_minion_jobs => '',
        },
        carry_over => \%CARRY_OVER_DEFAULTS,
        'test_preset example' => {
            title => 'Create example test',
            info => 'Parameters to create an example test have been pre-filled in the following form. '
              . 'You can simply submit the form as-is to test your openQA setup.',
            casedir => 'https://github.com/os-autoinst/os-autoinst-distri-example.git',
            distri => 'example',
            build => 'openqa',
        });

    # in development mode we use fake auth and log to stderr
    my %mode_defaults = (
        development => {
            auth => {
                method => 'Fake',
            },
            logging => {
                file => undef,
                level => 'debug',
            },
        },
        test => {
            auth => {
                method => 'Fake',
            },
            logging => {
                file => undef,
                level => 'debug',
            },
        });

    # Mojo's built in config plugins suck. JSON for example does not
    # support comments
    my $cfg;
    my $cfgpath = $ENV{OPENQA_CONFIG} ? path($ENV{OPENQA_CONFIG}) : $app->home->child('etc', 'openqa');
    my $cfgfile = $cfgpath->child('openqa.ini');
    my $config = $app->config;

    if (-e $cfgfile) {
        $cfg = Config::IniFiles->new(-file => $cfgfile->to_string) || undef;
        $config->{ini_config} = $cfg;
    }
    else {
        $app->log->warn('No configuration file supplied, will fallback to default configuration');
    }

    for my $section (sort keys %defaults) {
        my @known_keys = sort keys %{$defaults{$section}};
        # if no known_keys defined - just assign every key from the section
        if (!@known_keys && $cfg) {
            for my $k ($cfg->Parameters($section)) {
                $config->{$section}->{$k} = $cfg->val($section, $k);
            }
        }
        for my $k (@known_keys) {
            my $v = $cfg && $cfg->val($section, $k);
            $v //= $mode_defaults{$app->mode}{$section}->{$k} // $defaults{$section}->{$k};
            $config->{$section}->{$k} = trim $v if defined $v;
        }
    }
    my $global_config = $config->{global};
    $global_config->{recognized_referers} = [split(/\s+/, $global_config->{recognized_referers})];
    if (my $regex = $global_config->{auto_clone_regex}) {
        $app->log->warn(
            "Specified auto_clone_regex is invalid: $@Not restarting any jobs reported as incomplete by workers.")
          unless eval { $global_config->{auto_clone_regex} = qr/$regex/ };
    }
    $config->{_openid_secret} = random_string(16);
    $config->{auth}->{method} =~ s/\s//g;
    if ($config->{audit}->{blacklist}) {
        $app->log->warn("Deprecated use of config key '[audit]: blacklist'. Use '[audit]: blocklist' instead");
        $config->{audit}->{blocklist} = delete $config->{audit}->{blacklist};
    }
    my $minion_task_triggers = $config->{minion_task_triggers};
    $minion_task_triggers->{$_} = [split(/\s+/, $minion_task_triggers->{$_})] for keys %{$minion_task_triggers};
    if (my $minion_fail_job_blocklist = $config->{influxdb}->{ignored_failed_minion_jobs}) {
        $config->{influxdb}->{ignored_failed_minion_jobs} = [split(/\s+/, $minion_fail_job_blocklist)];
    }
    my $results = delete $global_config->{parallel_children_collapsable_results};
    $global_config->{parallel_children_collapsable_results_sel}
      = ' .status' . join('', map { ":not(.result_$_)" } split(/\s+/, $results));
    _validate_worker_timeout($app);
}

sub _validate_worker_timeout ($app) {
    my $global_config = $app->config->{global};
    my $configured_worker_timeout = $global_config->{worker_timeout};
    if (!looks_like_number($configured_worker_timeout) || $configured_worker_timeout < MAX_TIMER) {
        $global_config->{worker_timeout} = DEFAULT_WORKER_TIMEOUT;
        $app->log->warn(
            'The specified worker_timeout is invalid and will be ignored. The timeout must be an integer greater than '
              . MAX_TIMER
              . '.');
    }
}

# Update config definition from plugin requests
sub update_config ($config, @namespaces) {
    return unless exists $config->{ini_config};

    # Filter out what plugins are loaded from the used namespaces
    foreach my $plugin (loaded_plugins(@namespaces)) {

        # We take config only if the plugin has the method declared
        next unless ($plugin->can('configuration_fields'));

        # If it is a Mojo::Base class, it requires to be instantiated
        # because the attributes are not populated until creation.
        my $fields
          = UNIVERSAL::isa($plugin, 'Mojo::Base')
          ? do { $plugin->new->configuration_fields() }
          : $plugin->configuration_fields();

        # We expect just hashrefs
        next unless (ref($fields) eq 'HASH');

        # Walk the hash with the plugin returns that needs to be fetched
        # by our Ini file parser and fill config from it
        hashwalker $fields => sub ($key, $, $keys) {
            my $v = $config->{ini_config}->val(@$keys[0], $key);
            $config->{@$keys[0]}->{$key} = $v if defined $v;
        };
    }
}

sub prepare_settings_ui_keys ($app) {
    my @link_keys = split ',', $app->config->{job_settings_ui}->{keys_to_render_as_links};
    $app->config->{settings_ui_links} = {map { $_ => 1 } @link_keys};
}

sub setup_app_defaults ($server) {
    $server->defaults(appname => $server->app->config->{global}->{appname});
    $server->defaults(current_version => detect_current_version($server->app->home));
}

sub setup_template_search_path ($server) { unshift @{$server->renderer->paths}, '/etc/openqa/templates' }

sub setup_plain_exception_handler ($app) {
    $app->routes->any('/*whatever' => {whatever => ''})->to(status => 404, text => 'Not found');
    $app->helper(
        'reply.exception' => sub ($c, $error) {
            my $app = $c->app;
            $error = blessed $error && $error->isa('Mojo::Exception') ? $error : Mojo::Exception->new($error);
            $error = $error->inspect;
            $app->log->error($error);
            $error = 'internal error' if ($app->mode ne 'development');
            $c->render(text => $error, status => 500);
        });
}

sub setup_mojo_tmpdir () {
    unless ($ENV{MOJO_TMPDIR}) {
        $ENV{MOJO_TMPDIR} = assetdir() . '/tmp';
        # Try to create tmpdir if it doesn't exist but don't die if failed to create
        if (!-e $ENV{MOJO_TMPDIR}) {
            eval { make_path($ENV{MOJO_TMPDIR}); };
            print STDERR "Can not create MOJO_TMPDIR : $@\n" if $@;
        }
        delete $ENV{MOJO_TMPDIR} unless -w $ENV{MOJO_TMPDIR};
    }
}

sub load_plugins ($server, $monitoring_root_route = undef, %options) {
    push @{$server->plugins->namespaces}, 'OpenQA::WebAPI::Plugin';
    $server->plugin($_) for qw(Helpers MIMETypes CSRF REST Gru YAML);
    $server->plugin('AuditLog') if $server->config->{global}{audit_enabled};
    # Load arbitrary plugins defined in config: 'plugins' in section
    # '[global]' can be a space-separated list of plugins to load, by
    # module name under OpenQA::WebAPI::Plugin::
    if (defined $server->config->{global}->{plugins} && !$options{no_arbitrary_plugins}) {
        my @plugins = split(' ', $server->config->{global}->{plugins});
        for my $plugin (@plugins) {
            $server->log->info("Loading external plugin $plugin");
            $server->plugin($plugin);
        }
    }
    $server->plugin(NYTProf => {nytprof => {}}) if $server->config->{global}{profiling_enabled};
    $server->plugin(Status => {route => $monitoring_root_route->get('/monitoring')})
      if $monitoring_root_route && $server->config->{global}{monitoring_enabled};
    # load auth module
    my $auth_method = $server->config->{auth}->{method};
    my $auth_module = "OpenQA::WebAPI::Auth::$auth_method";
    if (my $err = load_class $auth_module) {
        $err = 'Module not found' unless ref $err;
        die "Unable to load auth module $auth_module: $err";
    }
    # Optional initialization with access to the app
    if (my $sub = $auth_module->can('auth_setup')) {
        $server->$sub;
    }

    # Read configurations expected by plugins.
    OpenQA::Setup::update_config($server->config, @{$server->plugins->namespaces}, 'OpenQA::WebAPI::Auth');
}

sub set_secure_flag_on_cookies ($c) {
    $c->app->sessions->secure(1) if $c->req->is_secure;
    if (my $days = $c->app->config->{global}->{hsts}) {
        $c->res->headers->header(
            'Strict-Transport-Security' => sprintf('max-age=%d; includeSubDomains', $days * 24 * 60 * 60));
    }
}

sub set_secure_flag_on_cookies_of_https_connection ($server) {
    $server->hook(before_dispatch => \&set_secure_flag_on_cookies);
}

sub setup_validator_check_for_datetime ($server) {
    $server->validator->add_check(
        datetime => sub ($validation, $name, $value) {
            eval { DateTime::Format::Pg->parse_datetime($value); };
            return 1 if $@;
            return;
        });
}

# add build_tx time to the header for HMAC time stamp check to avoid large timeouts on uploads
sub add_build_tx_time_header ($app) {
    $app->hook(after_build_tx => sub ($tx, $app) { $tx->req->headers->header('X-Build-Tx-Time' => time) });
}

1;
