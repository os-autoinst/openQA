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

BEGIN {
    unshift @INC, 'lib';
}

use FindBin;
use lib "$FindBin::Bin/lib";
use Mojo::Base -strict;
use Mojo::File 'tempdir';
use Test::Fatal;
use Test::Output 'combined_like';
use Test::More;
use OpenQA::Worker;
use OpenQA::Worker::Job;

$ENV{OPENQA_CONFIG} = "$FindBin::Bin/data/24-worker-overall";

like(
    exception {
        OpenQA::Worker->new({instance => 'foo'});
    },
    qr{.*the specified instance number \"foo\" is no number.*},
    'instance number must be a number',
);

my $worker = OpenQA::Worker->new({instance => 1, apikey => 'foo', apisecret => 'bar', verbose => 1});
ok(my $settings = $worker->settings, 'settings instantiated');
delete $settings->global_settings->{LOG_DIR};
$worker->init;
my @webui_hosts = sort keys %{$worker->clients_by_webui_host};
is_deeply(\@webui_hosts, [qw(http://localhost:9527 https://remotehost)], 'client for each web UI host')
  or diag explain \@webui_hosts;

subtest 'setup info' => sub {
    my $setup_info = $worker->log_setup_info;
    like($setup_info, qr/.*http:\/\/localhost:9527,https:\/\/remotehost.*/, 'setup info contains hosts');
    like($setup_info, qr/.*qemu_i386,qemu_x86_64.*/, 'setup info contains worker classes');
};

subtest 'capabilities' => sub {
    my $capabilities      = $worker->capabilities;
    my @capabilities_keys = sort keys %$capabilities;
    is_deeply(
        \@capabilities_keys,
        [
            qw(
              cpu_arch cpu_modelname cpu_opmode host instance isotovideo_interface_version
              mem_max websocket_api_version worker_class
              )
        ],
        'capabilities contain expected information'
    ) or diag explain \@capabilities_keys;
};

subtest 'status' => sub {
    is_deeply(
        $worker->status,
        {
            type   => 'worker_status',
            status => 'free'
        },
        'worker is free by default'
    );

    my $job = OpenQA::Worker::Job->new($worker, undef, {some => 'info'});
    $worker->current_job($job);
    $worker->current_webui_host('some host');
    is_deeply(
        $worker->status,
        {
            type               => 'worker_status',
            status             => 'working',
            job                => {some => 'info'},
            current_webui_host => 'some host'
        },
        'worker is "working" if job assigned'
    );

    $worker->current_job(undef);
    $worker->settings->global_settings->{CACHEDIRECTORY} = 'foo';
    is_deeply(
        $worker->status,
        {
            type   => 'worker_status',
            status => 'broken',
            reason => 'Cache service not reachable.'
        },
        'worker is broken if CACHEDIRECTORY set but worker cache not available'
    );
};

subtest 'check negative cases for is_qemu_running' => sub {
    my $pool_directory = tempdir('poolXXXX');
    $worker->pool_directory($pool_directory);

    $pool_directory->child('qemu.pid')->spurt('999999999999999999');
    is($worker->is_qemu_running, undef, 'QEMU not considered running if PID invalid');

    $pool_directory->child('qemu.pid')->spurt($$);
    is($worker->is_qemu_running, undef, 'QEMU not considered running if PID is not a qemu process');
};

done_testing();
