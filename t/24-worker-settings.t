#!/usr/bin/env perl
# Copyright 2019-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings ':report_warnings';

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '8';
use OpenQA::Worker::Settings;
use OpenQA::Worker::App;
use Test::MockModule;
use Mojo::Util 'scope_guard';
use Mojo::File qw(path tempdir);

$ENV{OPENQA_CONFIG} = "$FindBin::Bin/data/24-worker-settings";
$ENV{OPENQA_WORKER_TERMINATE_AFTER_JOBS_DONE} = 1;

my $workdir = tempdir("$FindBin::Script-XXXX", TMPDIR => 1);
chdir $workdir;
my $guard = scope_guard sub { chdir $FindBin::Bin };

my $settings = OpenQA::Worker::Settings->new;

is_deeply(
    $settings->global_settings,
    {
        CRITICAL_LOAD_AVG_THRESHOLD => 40,
        GLOBAL => 'setting',
        WORKER_HOSTNAME => '127.0.0.1',
        LOG_LEVEL => 'test',
        LOG_DIR => 'log/dir',
        RETRY_DELAY => 5,
        RETRY_DELAY_IF_WEBUI_BUSY => 60,
        TERMINATE_AFTER_JOBS_DONE => 1,
    },
    'global settings, spaces trimmed'
) or always_explain $settings->global_settings;

is($settings->file_path, "$FindBin::Bin/data/24-worker-settings/workers.ini", 'file path set');
is_deeply($settings->parse_errors, [], 'no parse errors occurred');

is_deeply($settings->webui_hosts, ['http://localhost:9527', 'https://remotehost'], 'web UI hosts, spaces trimmed')
  or always_explain $settings->webui_hosts;

is_deeply(
    $settings->webui_host_specific_settings,
    {
        'http://localhost:9527' => {
            HOST_SPECIFIC => 'setting (localhost)',
        },
        'https://remotehost' => {
            HOST_SPECIFIC => 'specific setting (remotehost)',
        },
    },
    'web UI host specific settings'
) or always_explain $settings->webui_host_specific_settings;

delete $ENV{OPENQA_WORKER_TERMINATE_AFTER_JOBS_DONE};

subtest 'check for local worker' => sub {
    ok !$settings->is_local_worker, 'not considered local worker due to remotehost and despite localhost:9527';

    $settings->{_local} = undef;
    $settings->webui_hosts->[1] = 'https://[::1]';    # test whether an IPv6 address works
    $settings->webui_hosts->[2] = 'localhost';    # test whether a "URL" without host/authority and only a path works
    ok $settings->is_local_worker, 'considered local with localhost:9527 and remotehost being changed to ::1';
};

subtest 'apply settings to app' => sub {
    my ($setup_log_called, $setup_log_app);
    my $mock = Test::MockModule->new('OpenQA::Worker::Settings');
    $mock->redefine(
        setup_log => sub {
            $setup_log_app = shift;
            $setup_log_called = 1;
        });
    my $app = OpenQA::Worker::App->new;
    $settings->apply_to_app($app);
    is($app->level, 'test', 'log level applied');
    is($app->log_dir, 'log/dir', 'log dir applied');
    is($setup_log_called, 1, 'setup_log called');
    is($setup_log_app, $app, 'setup_log called with the right application');
};

subtest 'instance-specific and WORKER_CLASS-specific settings' => sub {
    my $settings1 = OpenQA::Worker::Settings->new(1);
    is_deeply(
        $settings1->global_settings,
        {
            CRITICAL_LOAD_AVG_THRESHOLD => 40,
            GLOBAL => 'setting',
            WORKER_HOSTNAME => '127.0.0.1',
            WORKER_CLASS => 'qemu_i386,qemu_x86_64',
            LOG_LEVEL => 'test',
            LOG_DIR => 'log/dir',
            RETRY_DELAY => 5,
            RETRY_DELAY_IF_WEBUI_BUSY => 60,
        },
        'global settings (instance 1)'
    ) or always_explain $settings1->global_settings;
    my $settings2 = OpenQA::Worker::Settings->new(2);
    is_deeply(
        $settings2->global_settings,
        {
            CRITICAL_LOAD_AVG_THRESHOLD => 40,
            GLOBAL => 'setting',
            WORKER_HOSTNAME => '127.0.0.1',
            WORKER_CLASS => 'special-hardware,qemu_aarch64',
            LOG_LEVEL => 'test',
            LOG_DIR => 'log/dir',
            FOO => 'setting from slot has precedence',
            BAR => 'aarch64-specific-setting',
            RETRY_DELAY => 10,
            RETRY_DELAY_IF_WEBUI_BUSY => 120,
        },
        'global settings (instance 2)'
    ) or always_explain $settings2->global_settings;
};

subtest 'settings file with errors' => sub {
    $ENV{OPENQA_CONFIG} = "$FindBin::Bin/data/24-worker-settings-error";
    my $settings = OpenQA::Worker::Settings->new(1);
    is_deeply($settings->parse_errors, ['3: parameter found outside a section'], 'error logged')
      or always_explain $settings->parse_errors;
};

subtest 'settings file not found' => sub {
    my $config_mock = Test::MockModule->new('OpenQA::Config');
    $config_mock->redefine(_config_dirs => [['does not exist']]);
    my $settings = OpenQA::Worker::Settings->new(1);
    ok !$settings->file_path, 'no file path present';
    is_deeply $settings->parse_errors, ['No config file found.'], 'error logged'
      or always_explain $settings->parse_errors;
};

done_testing();
