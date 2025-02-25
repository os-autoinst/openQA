# Copyright 2014-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";

use Test::Warnings ':report_warnings';
use Test::Output 'combined_like';
use Mojolicious;
use OpenQA::Constants qw(DEFAULT_WORKER_TIMEOUT MAX_TIMER);
use OpenQA::Test::TimeLimit '4';
use OpenQA::Setup;
use OpenQA::JobGroupDefaults;
use OpenQA::Task::Job::Limit;
use Mojo::File 'tempdir';
use Time::Seconds;

sub read_config {
    my ($app, $msg) = @_;
    $msg //= 'reading config from default';
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    combined_like sub { OpenQA::Setup::read_config($app) }, qr/fallback to default/, $msg;
    return $app->config;
}

subtest 'Test configuration default modes' => sub {
    local $ENV{OPENQA_CONFIG} = undef;

    my $app = Mojolicious->new();
    $app->mode("test");
    my $config = read_config($app, 'reading config from default with mode test');
    is(length($config->{_openid_secret}), 16, "config has openid_secret");
    my $test_config = {
        global => {
            appname => 'openQA',
            branding => 'openSUSE',
            hsts => 365,
            audit_enabled => 1,
            max_rss_limit => 0,
            profiling_enabled => 0,
            monitoring_enabled => 0,
            hide_asset_types => 'repo',
            recognized_referers => [],
            changelog_file => '/usr/share/openqa/public/Changelog',
            job_investigate_ignore => '"(JOBTOKEN|NAME)"',
            job_investigate_git_timeout => 20,
            job_investigate_git_log_limit => 200,
            search_results_limit => 50000,
            worker_timeout => DEFAULT_WORKER_TIMEOUT,
            force_result_regex => '',
            parallel_children_collapsable_results_sel => ' .status:not(.result_passed):not(.result_softfailed)',
            auto_clone_limit => 20,
            api_hmac_time_tolerance => 300,
        },
        rate_limits => {
            search => 5,
        },
        auth => {
            method => 'Fake',
            require_for_assets => 0,
        },
        'scm git' => {
            update_remote => '',
            update_branch => '',
            do_push => 'no',
            do_cleanup => 'no',
            git_auto_clone => 'yes',
            git_auto_update => 'yes',
            git_auto_update_method => 'best-effort',
        },
        'scheduler' => {
            max_job_scheduled_time => 7,
            max_running_jobs => -1,
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
            id_from => 'id',
            nickname_from => '',
            unique_name => '',
        },
        hypnotoad => {
            listen => ['http://localhost:9526/'],
            proxy => 1,
        },
        audit => {
            blacklist => '',
            blocklist => '',
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
            ssh_key_file => '',
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
            on_job_done => [],
        },
        misc_limits => {
            untracked_assets_storage_duration => 14,
            result_cleanup_max_free_percentage => 100,
            asset_cleanup_max_free_percentage => 100,
            screenshot_cleanup_batch_size => OpenQA::Task::Job::Limit::DEFAULT_SCREENSHOTS_PER_BATCH,
            screenshot_cleanup_batches_per_minion_job => OpenQA::Task::Job::Limit::DEFAULT_BATCHES_PER_MINION_JOB,
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
        influxdb => {
            ignored_failed_minion_jobs => '',
        },
        carry_over => {
            lookup_depth => 10,
            state_changes_limit => 3,
        },
        secrets => {github_token => ''},
    };

    # Test configuration generation with "test" mode
    $test_config->{_openid_secret} = $config->{_openid_secret};
    $test_config->{logging}->{level} = "debug";
    $test_config->{global}->{service_port_delta} = 2;
    is ref delete $config->{global}->{auto_clone_regex}, 'Regexp', 'auto_clone_regex parsed as regex';
    ok delete $config->{'test_preset example'}, 'default values for example tests assigned';
    is_deeply $config, $test_config, '"test" configuration';

    # Test configuration generation with "development" mode
    $app = Mojolicious->new(mode => 'development');
    $config = read_config($app, 'reading config from default with mode development');
    $test_config->{_openid_secret} = $config->{_openid_secret};
    $test_config->{global}->{service_port_delta} = 2;
    delete $config->{global}->{auto_clone_regex};
    delete $config->{'test_preset example'};
    is_deeply $config, $test_config, 'right "development" configuration';

    # Test configuration generation with an unknown mode (should fallback to default)
    $app = Mojolicious->new(mode => 'foo_bar');
    $config = read_config($app, 'reading config from default with mode foo_bar');
    $test_config->{_openid_secret} = $config->{_openid_secret};
    $test_config->{auth}->{method} = "OpenID";
    $test_config->{global}->{service_port_delta} = 2;
    delete $config->{global}->{auto_clone_regex};
    delete $config->{'test_preset example'};
    delete $test_config->{logging};
    is_deeply $config, $test_config, 'right default configuration';
};

subtest 'Test configuration override from file' => sub {
    my $t_dir = tempdir;
    local $ENV{OPENQA_CONFIG} = $t_dir;
    my $app = Mojolicious->new();
    my @data = (
        "[global]\n",
        "suse_mirror=http://blah/\n",
        "recognized_referers = bugzilla.suse.com bugzilla.opensuse.org progress.opensuse.org github.com\n",
        "[audit]\n",
        "blacklist = job_grab job_done\n",
        "[assets/storage_duration]\n",
        "-CURRENT = 40\n",
        "[minion_task_triggers]\n",
        "on_job_done = spam eggs\n",
        "[influxdb]\n",
        "ignored_failed_minion_jobs = foo boo\n"

    );
    $t_dir->child("openqa.ini")->spew(join '', @data);
    combined_like sub { OpenQA::Setup::read_config($app) }, qr/Deprecated.*blacklist/, 'notice about deprecated key';

    ok -e $t_dir->child("openqa.ini");
    ok $app->config->{global}->{suse_mirror} eq 'http://blah/', 'suse mirror';
    ok $app->config->{audit}->{blocklist} eq 'job_grab job_done', 'audit blocklist migrated from deprecated key name';
    is $app->config->{'assets/storage_duration'}->{'-CURRENT'}, 40, 'assets/storage_duration';

    is_deeply(
        $app->config->{global}->{recognized_referers},
        [qw(bugzilla.suse.com bugzilla.opensuse.org progress.opensuse.org github.com)],
        'referers parsed correctly'
    );

    is_deeply($app->config->{minion_task_triggers}->{on_job_done},
        [qw(spam eggs)], 'parse minion task triggers correctly');
    is_deeply($app->config->{influxdb}->{ignored_failed_minion_jobs},
        [qw(foo boo)], 'parse ignored_failed_minion_jobs correctly');
};

subtest 'trim whitespace characters from both ends of openqa.ini value' => sub {
    my $t_dir = tempdir;
    local $ENV{OPENQA_CONFIG} = $t_dir;
    my $app = Mojolicious->new();
    my $data = '
        [global]
        appname =  openQA  
        hide_asset_types = repo iso  
        recognized_referers =   bugzilla.suse.com   progress.opensuse.org github.com
    ';
    $t_dir->child('openqa.ini')->spew($data);
    my $global_config = OpenQA::Setup::read_config($app)->{global};
    is $global_config->{appname}, 'openQA', 'appname';
    is $global_config->{hide_asset_types}, 'repo iso', 'hide_asset_types';
    is_deeply $global_config->{recognized_referers},
      [qw(bugzilla.suse.com progress.opensuse.org github.com)],
      'recognized_referers';
};

subtest 'Validation of worker timeout' => sub {
    my $app = Mojolicious->new(config => {global => {worker_timeout => undef}});
    my $configured_timeout = \$app->config->{global}->{worker_timeout};
    subtest 'too low worker_timeout' => sub {
        $$configured_timeout = MAX_TIMER - 1;
        combined_like { OpenQA::Setup::_validate_worker_timeout($app) } qr/worker_timeout.*invalid/, 'warning logged';
        is $$configured_timeout, DEFAULT_WORKER_TIMEOUT, 'rejected';
    };
    subtest 'minimum worker_timeout' => sub {
        $$configured_timeout = MAX_TIMER;
        OpenQA::Setup::_validate_worker_timeout($app);
        is $$configured_timeout, MAX_TIMER, 'accepted';
    };
    subtest 'invalid worker_timeout' => sub {
        $$configured_timeout = 'invalid';
        combined_like { OpenQA::Setup::_validate_worker_timeout($app) } qr/worker_timeout.*invalid/, 'warning logged';
        is $$configured_timeout, DEFAULT_WORKER_TIMEOUT, 'rejected';
    };
};

subtest 'Multiple config files' => sub {
    my $t_dir = tempdir;
    my $openqa_d = $t_dir->child('openqa.d')->make_path;
    local $ENV{OPENQA_CONFIG} = $t_dir;
    my $app = Mojolicious->new();
    my $data_main = "[global]\nappname =  openQA main config\nhide_asset_types = repo iso\n";
    my $data_01 = "[global]\nappname =  openQA override 1\nscm = bazel";
    my $data_02 = "[global]\nappname =  openQA override 2";
    $t_dir->child('openqa.ini')->spew($data_main);
    $openqa_d->child('01-appname-and-scm.ini')->spew($data_01);
    $openqa_d->child('02-appname.ini')->spew($data_02);
    my $global_config = OpenQA::Setup::read_config($app)->{global};
    is $global_config->{appname}, 'openQA override 2', 'appname overriden by config from openqa.d, last one wins';
    is $global_config->{scm}, 'bazel', 'scm set by config from openqa.d, not overriden';
    is $global_config->{hide_asset_types}, 'repo iso', 'types set from main config, not overriden';
};

done_testing();
