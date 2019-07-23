#! /usr/bin/perl

# Copyright (C) 2019 SUSE LLC
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use strict;
use warnings;

use FindBin;
use lib ("$FindBin::Bin/lib", "$FindBin::Bin/../lib");
use Mojo::Base -strict;
use Test::More;
use OpenQA::Worker::Settings;

$ENV{OPENQA_CONFIG} = "$FindBin::Bin/data/24-worker-settings";

my $settings = OpenQA::Worker::Settings->new;

is_deeply(
    $settings->global_settings,
    {
        GLOBAL          => 'setting',
        WORKER_HOSTNAME => '127.0.0.1',
        LOG_LEVEL       => 'test',
        LOG_DIR         => 'log/dir',
    },
    'global settings, spaces trimmed'
) or diag explain $settings->global_settings;

is($settings->file_path, "$FindBin::Bin/data/24-worker-settings/workers.ini", 'file path set');
is_deeply($settings->parse_errors, [], 'no parse errors occurred');

is_deeply($settings->webui_hosts, ['http://localhost:9527', 'https://remotehost'], 'web UI hosts, spaces trimmed')
  or diag explain $settings->webui_hosts;

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
) or diag explain $settings->webui_host_specific_settings;

subtest 'apply settings to app' => sub {
    {
        package Test::FakeApp;
        use Mojo::Base -base;
        has 'level';
        has 'log_dir';
        has 'setup_log_called';
        sub setup_log {
            shift->setup_log_called(1);
        }
    }

    my $app = Test::FakeApp->new;
    $settings->apply_to_app($app);
    is($app->level,            'test',    'log level applied');
    is($app->log_dir,          'log/dir', 'log dir applied');
    is($app->setup_log_called, 1,         'setup_log called');
};

subtest 'instance-specific settings' => sub {
    my $settings1 = OpenQA::Worker::Settings->new(1);
    is_deeply(
        $settings1->global_settings,
        {
            GLOBAL          => 'setting',
            WORKER_HOSTNAME => '127.0.0.1',
            WORKER_CLASS    => 'qemu_i386,qemu_x86_64',
            LOG_LEVEL       => 'test',
            LOG_DIR         => 'log/dir',
        },
        'global settings (instance 1)'
    ) or diag explain $settings1->global_settings;
    my $settings2 = OpenQA::Worker::Settings->new(2);
    is_deeply(
        $settings2->global_settings,
        {
            GLOBAL          => 'setting',
            WORKER_HOSTNAME => '127.0.0.1',
            WORKER_CLASS    => 'qemu_aarch64',
            LOG_LEVEL       => 'test',
            LOG_DIR         => 'log/dir',
            FOO             => 'bar',
        },
        'global settings (instance 2)'
    ) or diag explain $settings2->global_settings;
};

subtest 'settings file not found' => sub {
    $ENV{OPENQA_CONFIG} = "$FindBin::Bin/data/24-worker-settings-error";
    my $settings = OpenQA::Worker::Settings->new(1);
    is_deeply($settings->parse_errors, ['3: parameter found outside a section'], 'error logged')
      or diag explain $settings->parse_errors;
};

subtest 'settings file not found' => sub {
    $ENV{OPENQA_CONFIG} = "$FindBin::Bin/data/24-worker-setting";
    my $settings = OpenQA::Worker::Settings->new(1);
    is($settings->file_path, undef, 'no file path present');
    is_deeply($settings->parse_errors, ["Config file not found at '$FindBin::Bin/data/24-worker-setting/workers.ini'."],
        'error logged')
      or diag explain $settings->parse_errors;
};

done_testing();
