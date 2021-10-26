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
            search_results_limit => 50000,
            worker_timeout => DEFAULT_WORKER_TIMEOUT,
            force_result_regex => '',
        },
        rate_limits => {
            search => 5,
        },
        auth => {
            method => 'Fake',
        },
        'scm git' => {
            update_remote => '',
            update_branch => '',
            do_push => 'no',
        },
        'scheduler' => {
            max_job_scheduled_time => 7,
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
        },
        obs_rsync => {
            home => '',
            retry_interval => 60,
            retry_max_count => 1400,
            queue_limit => 200,
            concurrency => 2,
            project_status_url => '',
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
        minion_task_triggers => {
            on_job_done => [],
        },
        misc_limits => {
            untracked_assets_storage_duration => 14,
            result_cleanup_max_free_percentage => 100,
            asset_cleanup_max_free_percentage => 100,
            screenshot_cleanup_batch_size => OpenQA::Task::Job::Limit::DEFAULT_SCREENSHOTS_PER_BATCH,
            screenshot_cleanup_batches_per_minion_job => OpenQA::Task::Job::Limit::DEFAULT_BATCHES_PER_MINION_JOB,
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
    };

    # Test configuration generation with "test" mode
    $test_config->{_openid_secret} = $config->{_openid_secret};
    $test_config->{logging}->{level} = "debug";
    is ref delete $config->{global}->{auto_clone_regex}, 'Regexp', 'auto_clone_regex parsed as regex';
    is_deeply $config, $test_config, '"test" configuration';

    # Test configuration generation with "development" mode
    $app = Mojolicious->new();
    $app->mode("development");
    $config = read_config($app, 'reading config from default with mode development');
    $test_config->{_openid_secret} = $config->{_openid_secret};
    delete $config->{global}->{auto_clone_regex};
    is_deeply $config, $test_config, 'right "development" configuration';

    # Test configuration generation with an unknown mode (should fallback to default)
    $app = Mojolicious->new();
    $app->mode("foo_bar");
    $config = read_config($app, 'reading config from default with mode foo_bar');
    $test_config->{_openid_secret} = $config->{_openid_secret};
    $test_config->{auth}->{method} = "OpenID";
    delete $config->{global}->{auto_clone_regex};
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
"recognized_referers = bugzilla.suse.com bugzilla.opensuse.org bugzilla.novell.com bugzilla.microfocus.com progress.opensuse.org github.com\n",
        "[audit]\n",
        "blacklist = job_grab job_done\n",
        "[assets/storage_duration]\n",
        "-CURRENT = 40\n",
        "[minion_task_triggers]\n",
        "on_job_done = spam eggs\n",
        "[influxdb]\n",
        "ignored_failed_minion_jobs = foo boo\n"

    );
    $t_dir->child("openqa.ini")->spurt(@data);
    combined_like sub { OpenQA::Setup::read_config($app) }, qr/Deprecated.*blacklist/, 'notice about deprecated key';

    ok -e $t_dir->child("openqa.ini");
    ok $app->config->{global}->{suse_mirror} eq 'http://blah/', 'suse mirror';
    ok $app->config->{audit}->{blocklist} eq 'job_grab job_done', 'audit blocklist migrated from deprecated key name';
    is $app->config->{'assets/storage_duration'}->{'-CURRENT'}, 40, 'assets/storage_duration';

    is_deeply(
        $app->config->{global}->{recognized_referers},
        [
            qw(bugzilla.suse.com bugzilla.opensuse.org bugzilla.novell.com bugzilla.microfocus.com progress.opensuse.org github.com)
        ],
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
        recognized_referers =   bugzilla.suse.com   bugzilla.novell.com   bugzilla.microfocus.com   progress.opensuse.org github.com
    ';
    $t_dir->child('openqa.ini')->spurt($data);
    OpenQA::Setup::read_config($app);
    ok($app->config->{global}->{appname} eq 'openQA', 'appname');
    ok($app->config->{global}->{hide_asset_types} eq 'repo iso', 'hide_asset_types');
    is_deeply(
        $app->config->{global}->{recognized_referers},
        [qw(bugzilla.suse.com bugzilla.novell.com bugzilla.microfocus.com progress.opensuse.org github.com)],
        'recognized_referers'
    );
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

done_testing();
