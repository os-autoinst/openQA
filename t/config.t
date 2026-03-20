# Copyright 2014-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";

use Test::Warnings ':report_warnings';
use Test::Output qw(combined_like stderr_like);
use Test::MockModule;
use Test::MockObject;
use Mojolicious;
use experimental 'signatures';
use Mojo::Log;
use OpenQA::App;
use OpenQA::Config;
use OpenQA::Constants qw(DEFAULT_WORKER_TIMEOUT MAX_TIMER);
use OpenQA::Test::TimeLimit '4';
use OpenQA::Setup;
use OpenQA::JobGroupDefaults;
use OpenQA::Task::Job::Limit;
use Mojo::File qw(path tempdir);
use Time::Seconds;
use Storable 'dclone';

my $quiet_log = Mojo::Log->new(level => 'warn');

sub read_config {
    my ($app, $msg) = @_;
    $msg //= 'reading config from default';
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    combined_like sub { OpenQA::Setup::read_config($app) }, qr/fallback to default/, $msg;
    return $app->config;
}

subtest 'Test configuration default modes' => sub {
    # test with a completely empty config file to check defaults
    # note: We cannot use no config file at all because then the lookup would fallback to a system configuration.
    my $t_dir = tempdir;
    $t_dir->child('openqa.ini')->touch;
    local $ENV{OPENQA_CONFIG} = $t_dir;

    OpenQA::App->set_singleton(my $app = Mojolicious->new(log => $quiet_log));
    $app->mode('test');
    my $config = read_config($app, 'reading config from default with mode test');
    is length($config->{_openid_secret}), 16, 'config has openid_secret';
    my $test_config = dclone(OpenQA::Setup::default_config());
    my $scheduler_config = $test_config->{scheduler};
    # apply transformations done in read_config
    $test_config->{global}->{recognized_referers} = [];
    $test_config->{global}->{parallel_children_collapsable_results_sel}
      = ' .status:not(.result_passed):not(.result_softfailed)';
    $test_config->{auth}->{method} = 'Fake';
    $test_config->{minion_task_triggers}->{on_job_done} = [];
    $scheduler_config->{results_min_free_storage_space_percentage} = 0;
    $scheduler_config->{assets_min_free_storage_space_percentage} = 0;
    $scheduler_config->{archive_min_free_storage_space_percentage} = 0;
    for my $l ($test_config->{default_group_limits}, $test_config->{no_group_limits}) {
        $l->{result_storage_duration} = OpenQA::JobGroupDefaults::KEEP_RESULTS_IN_DAYS;
        $l->{important_result_storage_duration} = OpenQA::JobGroupDefaults::KEEP_IMPORTANT_RESULTS_IN_DAYS;
        $l->{job_storage_duration} = OpenQA::JobGroupDefaults::KEEP_JOBS_IN_DAYS;
        $l->{important_job_storage_duration} = OpenQA::JobGroupDefaults::KEEP_IMPORTANT_JOBS_IN_DAYS;
    }
    delete $test_config->{'test_preset example'};
    delete $test_config->{global}->{auto_clone_regex};
    delete $test_config->{global}->{parallel_children_collapsable_results};
    for my $k (keys %$test_config) {
        my $section = $test_config->{$k};
        next unless ref $section eq 'HASH';
        delete $section->{$_} for grep { !defined $section->{$_} } keys %$section;
        delete $test_config->{$k} unless %$section;
    }

    # Test configuration generation with "test" mode
    $test_config->{_openid_secret} = $config->{_openid_secret};
    $test_config->{logging}->{level} = 'debug';
    $test_config->{global}->{service_port_delta} = 2;
    $test_config->{misc_limits}->{prio_throttling_data} = {MAX_JOB_TIME => {scale => '0.007', reference => 0}};
    $test_config->{misc_limits}->{prio_group_data} = [{property => 'name', regex => qr/Development/, increment => 50}];
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
    $test_config->{auth}->{method} = 'OpenID';
    $test_config->{global}->{service_port_delta} = 2;
    $scheduler_config->{results_min_free_storage_space_percentage} = 5;
    $scheduler_config->{assets_min_free_storage_space_percentage} = 5;
    $scheduler_config->{archive_min_free_storage_space_percentage} = 5;
    delete $config->{global}->{auto_clone_regex};
    delete $config->{'test_preset example'};
    delete $test_config->{logging};
    is_deeply $config, $test_config, 'right default configuration';
};

subtest 'Test configuration override from file' => sub {
    my $t_dir = tempdir;
    local $ENV{OPENQA_CONFIG} = $t_dir;
    OpenQA::App->set_singleton(my $app = Mojolicious->new(log => $quiet_log));
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
        "[default_group_limits]\n",
        "result_storage_duration = 0\n",
        "[no_group_limits]\n",
        "result_storage_duration = 731\n",
        "[influxdb]\n",
        "ignored_failed_minion_jobs = foo boo\n"

    );
    $t_dir->child('openqa.ini')->spew(join '', @data);
    combined_like sub { OpenQA::Setup::read_config($app) }, qr/Deprecated.*blacklist/, 'notice about deprecated key';

    ok -e $t_dir->child('openqa.ini');
    ok $app->config->{global}->{suse_mirror} eq 'http://blah/', 'suse mirror';
    ok $app->config->{audit}->{blocklist} eq 'job_grab job_done', 'audit blocklist migrated from deprecated key name';
    is $app->config->{'assets/storage_duration'}->{'-CURRENT'}, 40, 'assets/storage_duration';

    is_deeply
      $app->config->{global}->{recognized_referers},
      [qw(bugzilla.suse.com bugzilla.opensuse.org progress.opensuse.org github.com)],
      'referers parsed correctly';

    is_deeply $app->config->{minion_task_triggers}->{on_job_done},
      [qw(spam eggs)], 'parse minion task triggers correctly';
    is_deeply $app->config->{influxdb}->{ignored_failed_minion_jobs},
      [qw(foo boo)], 'parse ignored_failed_minion_jobs correctly';

    is $app->config->{default_group_limits}->{job_storage_duration}, 0,
      'default job_storage_duration extended to result_storage_duration';
    is $app->config->{no_group_limits}->{job_storage_duration}, 731,
      'default job_storage_duration extended to result_storage_duration (no group)';
};

subtest 'openqa.ini documentation check' => sub {
    my $defaults = OpenQA::Setup::default_config();
    my $ini_path = path($FindBin::Bin)->child('..', 'etc', 'openqa', 'openqa.ini');
    ok -r $ini_path, "can read $ini_path";
    my $content = $ini_path->slurp;

    my %documented;
    my $current_section;
    for (split /\n/, $content) {
        if (/^#?\[([^\]]+)\]/) {
            $current_section = $1;
        }
        elsif ($current_section && /^#?\s*([a-z0-9_]+)\s*=/) {
            $documented{$current_section}->{$1} = 1;
        }
    }

    for my $section (sort keys %$defaults) {
        # skip internal/dynamic sections
        next if $section =~ /^(plugin_links|hooks|test_preset example|assets\/storage_duration|carry_over)$/;
        for my $key (sort keys %{$defaults->{$section}}) {
            # skip deprecated/internal/currently undocumented keys
            next
              if $section eq 'global'
              && $key
              =~ /^(scm|parallel_children_collapsable_results_sel|file_domain|prio_throttling_data|access_control_allow_origin_header|changelog_file|file_subdomain|search_results_limit)$/;
            next if $section eq 'hypnotoad';
            next if $section eq 'job_settings_ui' && $key eq 'default_data_dir';
            next if $section eq 'misc_limits' && $key =~ /^(prio_throttling_data|prio_group_data|mcp_max_result_size)$/;
            next if $section eq 'rate_limits' && $key eq 'search';
            next if $section eq 'secrets';
            next if $section eq 'audit' && $key eq 'blacklist';
            ok $documented{$section}->{$key}, "key '$key' in section '[$section]' is documented in openqa.ini";
        }
    }
};

subtest 'trim whitespace characters from both ends of openqa.ini value' => sub {
    my $t_dir = tempdir;
    local $ENV{OPENQA_CONFIG} = $t_dir;
    OpenQA::App->set_singleton(my $app = Mojolicious->new(log => $quiet_log));
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
    my $app = Mojolicious->new(config => {global => {worker_timeout => undef}}, log => $quiet_log);
    my $configured_timeout = \$app->config->{global}->{worker_timeout};
    OpenQA::App->set_singleton($app);
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

subtest 'Validation of file_security_policy' => sub {
    my %config;
    my $app = Mojolicious->new(config => \%config, log => $quiet_log);
    for my $value (qw(insecure-browsing download-prompt)) {
        $config{file_security_policy} = $value;
        OpenQA::Setup::_validate_security_policy($app, \%config);
        is $config{file_security_policy}, $value, "$value is valid";
    }
    $config{file_security_policy} = 'wrong';
    combined_like { OpenQA::Setup::_validate_security_policy($app, \%config) } qr/Invalid.*security/, 'warning logged';
    is $config{file_security_policy}, 'download-prompt', 'default to "download-prompt" on invalid value';
    is $config{file_domain}, undef, 'file_domain not populated yet';
    $config{file_security_policy} = 'domain:openqa-foo';
    OpenQA::Setup::_validate_security_policy($app, \%config);
    is $config{file_domain}, 'openqa-foo', 'file_domain populated via "domain:"';
};

subtest 'Multiple config files' => sub {
    my $t_dir = tempdir;
    my $openqa_d = $t_dir->child('openqa.ini.d')->make_path;
    local $ENV{OPENQA_CONFIG} = $t_dir;
    OpenQA::App->set_singleton(my $app = Mojolicious->new(log => $quiet_log));
    my $data_main = "[global]\nappname =  openQA main config\nhide_asset_types = repo iso\n";
    my $data_01 = "[global]\nappname =  openQA override 1\nbranding = fedora";
    my $data_02 = "[global]\nappname =  openQA override 2";
    $t_dir->child('openqa.ini')->spew($data_main);
    $openqa_d->child('01-appname-and-scm.ini')->spew($data_01);
    $openqa_d->child('02-appname.ini')->spew($data_02);
    my $global_config = OpenQA::Setup::read_config($app)->{global};
    is $global_config->{appname}, 'openQA override 2', 'appname overriden by config from openqa.ini.d, last one wins';
    is $global_config->{branding}, 'fedora', 'scm set by config from openqa.ini.d, not overriden';
    is $global_config->{hide_asset_types}, 'repo iso', 'types set from main config, not overriden';
};

subtest 'Lookup precedence/hiding' => sub {
    my $t_dir = tempdir;
    my @args = (undef, 'openqa.ini');
    my $config_mock = Test::MockModule->new('OpenQA::Config');
    $config_mock->redefine(_config_dirs => [["$t_dir/override"], ["$t_dir/home"], ["$t_dir/admin", "$t_dir/package"]]);

    my @expected;
    is_deeply lookup_config_files(@args), \@expected, 'no config files found';

    @expected = ("$t_dir/package/openqa.ini", "$t_dir/package/openqa.ini.d/packager-drop-in.ini");
    $t_dir->child('package')->make_path->child('openqa.ini')->touch->sibling('openqa.ini.d')
      ->make_path->child('packager-drop-in.ini')->touch;
    is_deeply lookup_config_files(@args), \@expected, 'found config from package';

    splice @expected, 0, 0, "$t_dir/admin/openqa.ini.d/admin-drop-in.ini";
    $t_dir->child('admin')->make_path->child('openqa.ini.d')->make_path->child('admin-drop-in.ini')->touch;
    is_deeply lookup_config_files(@args), \@expected, 'additional config from admin does not hide config from packager';

    @expected = ("$t_dir/admin/openqa.ini", "$t_dir/admin/openqa.ini.d/admin-drop-in.ini");
    $t_dir->child('admin')->child('openqa.ini')->touch;
    is_deeply lookup_config_files(@args), \@expected, 'main config from admin hides config from packager';

    @expected = ("$t_dir/home/openqa.ini.d/home-drop-in.ini");
    $t_dir->child('home')->child('openqa.ini.d')->make_path->child('home-drop-in.ini')->touch;
    is_deeply lookup_config_files(@args), \@expected, 'drop-in in home hides all other config';

    @expected = ("$t_dir/override/openqa.ini.d/override-drop-in.ini");
    $t_dir->child('override')->child('openqa.ini.d')->make_path->child('override-drop-in.ini')->touch;
    is_deeply lookup_config_files(@args), \@expected, 'drop-in in overriden dir hides all other config';
};

subtest 'check throttling configuration validation and application' => sub {
    my $app = OpenQA::App->singleton();
    my $config = $app->config;

    subtest 'invalid prio_throttling_parameters' => sub {
        $config->{misc_limits}->{prio_throttling_parameters} = 'invalid';
        stderr_like {
            $config->{misc_limits}->{prio_throttling_data} = OpenQA::Setup::_load_prio_throttling($app, $config);
        }
        qr/Wrong format/, 'warn expected';
        is_deeply $config->{misc_limits}->{prio_throttling_data}, undef,
          'prio_throttling_data is empty hash for invalid';
    };
    subtest 'no prio_throttling_parameters' => sub {
        $config->{misc_limits}->{prio_throttling_parameters} = undef;
        $config->{misc_limits}->{prio_throttling_data} = OpenQA::Setup::_load_prio_throttling($app, $config);
        is $config->{misc_limits}->{prio_throttling_data}, undef, 'prio_throttling_data is undef when no parameters';
    };
    subtest 'empty string' => sub {
        $config->{misc_limits}->{prio_throttling_parameters} = '';
        $config->{misc_limits}->{prio_throttling_data} = OpenQA::Setup::_load_prio_throttling($app, $config);
        is $config->{misc_limits}->{prio_throttling_data}, undef, 'prio_throttling_data is undef for empty string';
    };
    subtest 'valid prio_throttling_parameter with space separators' => sub {
        $config->{misc_limits}->{prio_throttling_parameters} = 'KEY1ONE:  1.5';
        $config->{misc_limits}->{prio_throttling_data} = OpenQA::Setup::_load_prio_throttling($app, $config);
        is_deeply $config->{misc_limits}->{prio_throttling_data},
          {KEY1ONE => {scale => 1.5, reference => 0}},
          'prio_throttling_data parsed correctly';
    };
    subtest 'valid multiple prio_throttling_parameters keys' => sub {
        $config->{misc_limits}->{prio_throttling_parameters} = 'A:1.04,B:2:3,C:0.04:5';
        $config->{misc_limits}->{prio_throttling_data} = OpenQA::Setup::_load_prio_throttling($app, $config);
        is_deeply $config->{misc_limits}->{prio_throttling_data},
          {
            A => {scale => 1.04, reference => 0},
            B => {scale => 2, reference => 3},
            C => {scale => 0.04, reference => 5}
          },
          'prio_throttling_data parses multiple correctly';
    };

    subtest 'prio_group_parameters' => sub {
        subtest 'valid multiple rules' => sub {
            $config->{misc_limits}->{prio_group_parameters} = 'name:open:10,name:suse:5';
            my $rules = OpenQA::Setup::_load_prio_group_throttling($app, $config);
            is_deeply $rules,
              [
                {property => 'name', regex => qr/open/, increment => 10},
                {property => 'name', regex => qr/suse/, increment => 5}
              ],
              'prio_group_data parsed correctly';
        };

        subtest 'invalid rule format' => sub {
            $config->{misc_limits}->{prio_group_parameters} = 'invalid';
            stderr_like {
                my $rules = OpenQA::Setup::_load_prio_group_throttling($app, $config);
                is $rules, undef, 'returns undef for invalid';
            }
            qr/Wrong format/, 'warning logged';
        };
    };
};

done_testing();
