#! /usr/bin/perl

# Copyright (C) 2014-2016 SUSE LLC
# Copyright (C) 2016 Red Hat
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

BEGIN {
    unshift @INC, 'lib';
    $ENV{OPENQA_TEST_IPC} = 1;
}

use Mojo::Base -strict;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;
use OpenQA::Client;
use Mojo::IOLoop;
use Data::Dump;

use OpenQA::WebSockets;
use OpenQA::Scheduler;
use OpenQA::ResourceAllocator;

use OpenQA::Utils 'locate_asset';

OpenQA::Test::Case->new->init_data;

my $t = Test::Mojo->new('OpenQA::WebAPI');

# XXX: Test::Mojo loses it's app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(
    OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

sub lj {
    return unless $ENV{HARNESS_IS_VERBOSE};
    my $ret  = $t->get_ok('/api/v1/jobs')->status_is(200);
    my @jobs = @{$ret->tx->res->json->{jobs}};
    for my $j (@jobs) {
        printf "%d %-10s %s (%s)\n", $j->{id}, $j->{state}, $j->{name}, $j->{priority};
    }
}

sub find_job {
    my ($jobs, $newids, $name, $machine) = @_;
    my $ret;
    for my $j (@$jobs) {
        if ($j->{settings}->{TEST} eq $name && $j->{settings}->{MACHINE} eq $machine) {
            # take the last if there are more than one
            $ret = $j;
        }
    }

    return undef unless defined $ret;

    for my $id (@$newids) {
        return $ret if $id == $ret->{id};
    }
    return undef;
}

sub schedule_iso {
    my ($args, $status) = @_;
    $status //= 200;
    my $ret = $t->post_ok('/api/v1/isos', form => $args)->status_is($status);
    return $ret->tx->res;
}

# create Test DBus bus and service for fake WebSockets and Scheduler call
my $ws = OpenQA::WebSockets->new;
my $sh = OpenQA::Scheduler->new;
my $ra = OpenQA::ResourceAllocator->new;

my $ret;

my $iso = 'openSUSE-13.1-DVD-i586-Build0091-Media.iso';

$ret = $t->get_ok('/api/v1/jobs/99927')->status_is(200);
is($ret->tx->res->json->{job}->{state}, 'scheduled', 'job 99927 is scheduled');
$ret = $t->get_ok('/api/v1/jobs/99928')->status_is(200);
is($ret->tx->res->json->{job}->{state}, 'scheduled', 'job 99928 is scheduled');
$ret = $t->get_ok('/api/v1/jobs/99963')->status_is(200);
is($ret->tx->res->json->{job}->{state}, 'running', 'job 99963 is running');

$ret = $t->get_ok('/api/v1/jobs/99981')->status_is(200);
is($ret->tx->res->json->{job}->{state}, 'cancelled', 'job 99981 is cancelled');

$ret = $t->post_ok('/api/v1/jobs/99981/restart')->status_is(200);

$ret = $t->get_ok('/api/v1/jobs/99981')->status_is(200);
my $clone99981 = $ret->tx->res->json->{job}->{clone_id};

$ret = $t->get_ok("/api/v1/jobs/$clone99981")->status_is(200);
is($ret->tx->res->json->{job}->{state}, 'scheduled', 'job $clone99981 is scheduled');

lj;

my @tasks;
@tasks = $t->app->db->resultset("GruTasks")->search({taskname => 'download_asset'});
is(scalar @tasks, 0, 'we have no gru download tasks to start with');

# add a random comment on a scheduled but not started job so that this one
# later on is found as important and handled accordingly
$t->app->db->resultset("Jobs")->find(99928)->comments->create({text => 'any text', user_id => 99901});

# schedule the iso, this should not actually be possible. Only isos
# with different name should result in new tests...
my $res = schedule_iso(
    {
        ISO        => $iso,
        DISTRI     => 'opensuse',
        VERSION    => '13.1',
        FLAVOR     => 'DVD',
        ARCH       => 'i586',
        BUILD      => '0091',
        PRECEDENCE => 'original'
    });

is($res->json->{count}, 10, '10 new jobs created');
my @newids = @{$res->json->{ids}};
my $newid  = $newids[0];

$ret = $t->get_ok('/api/v1/jobs');
my @jobs = @{$ret->tx->res->json->{jobs}};

my $server_32       = find_job(\@jobs, \@newids, 'server',       '32bit');
my $client1_32      = find_job(\@jobs, \@newids, 'client1',      '32bit');
my $client2_32      = find_job(\@jobs, \@newids, 'client2',      '32bit');
my $advanced_kde_32 = find_job(\@jobs, \@newids, 'advanced_kde', '32bit');
my $kde_32          = find_job(\@jobs, \@newids, 'kde',          '32bit');
my $textmode_32     = find_job(\@jobs, \@newids, 'textmode',     '32bit');

is_deeply(
    $client1_32->{parents},
    {Parallel => [$server_32->{id}], Chained => []},
    "server_32 is only parent of client1_32"
);
is_deeply(
    $client2_32->{parents},
    {Parallel => [$server_32->{id}], Chained => []},
    "server_32 is only parent of client2_32"
);
is_deeply($server_32->{parents}, {Parallel => [], Chained => []}, "server_32 has no parents");
is($kde_32,          undef, 'kde is not created for 32bit machine');
is($advanced_kde_32, undef, 'advanced_kde is not created for 32bit machine');

my $server_64       = find_job(\@jobs, \@newids, 'server',       '64bit');
my $client1_64      = find_job(\@jobs, \@newids, 'client1',      '64bit');
my $client2_64      = find_job(\@jobs, \@newids, 'client2',      '64bit');
my $advanced_kde_64 = find_job(\@jobs, \@newids, 'advanced_kde', '64bit');
my $kde_64          = find_job(\@jobs, \@newids, 'kde',          '64bit');
my $textmode_64     = find_job(\@jobs, \@newids, 'textmode',     '64bit');

is_deeply(
    $client1_64->{parents},
    {Parallel => [$server_64->{id}], Chained => []},
    "server_64 is only parent of client1_64"
);
is_deeply(
    $client2_64->{parents},
    {Parallel => [$server_64->{id}], Chained => []},
    "server_64 is only parent of client2_64"
);
is_deeply($server_64->{parents}, {Parallel => [], Chained => []}, "server_64 has no parents");
eq_set($advanced_kde_64->{parents}->{Parallel}, [], 'advanced_kde_64 has no parallel parents');
eq_set(
    $advanced_kde_64->{parents}->{Chained},
    [$kde_64->{id}, $textmode_64->{id}],
    'advanced_kde_64 has two chained parents'
);

is($server_32->{group_id}, 1001, 'server_32 part of opensuse group');
is($server_32->{priority}, 40,   'server_32 has priority according to job template');
is($server_64->{group_id}, 1001, 'server_64 part of opensuse group');
is($server_64->{priority}, 40,   'server_64 has priority according to job template');

is($advanced_kde_32->{settings}->{PUBLISH_HDD_1},
    undef, 'variable expansion because kde is not created for 32 bit machine');
is($advanced_kde_64->{settings}->{PUBLISH_HDD_1}, 'opensuse-13.1-i586-kde-qemu64.qcow2', 'variable expansion');

# variable precedence
is($client1_32->{settings}->{PRECEDENCE}, 'original', "default precedence (post PRECEDENCE beats suite PRECEDENCE)");
is($client1_64->{settings}->{PRECEDENCE}, 'original', "default precedence (post PRECEDENCE beats suite PRECEDENCE)");
is($server_32->{settings}->{PRECEDENCE}, 'overridden', "precedence override (suite +PRECEDENCE beats post PRECEDENCE)");
is($server_64->{settings}->{PRECEDENCE}, 'overridden', "precedence override (suite +PRECEDENCE beats post PRECEDENCE)");

lj;

subtest 'old tests are cancelled unless they are marked as important' => sub {
    $ret = $t->get_ok('/api/v1/jobs/99927')->status_is(200);
    is($ret->tx->res->json->{job}->{state}, 'cancelled', 'job 99927 is cancelled');
    $ret = $t->get_ok('/api/v1/jobs/99928')->status_is(200);
    is($ret->tx->res->json->{job}->{state}, 'scheduled', 'job 99928 is marked as important and therefore preserved');
    $ret = $t->get_ok('/api/v1/jobs/99963')->status_is(200);
    is($ret->tx->res->json->{job}->{state}, 'running', 'job 99963 is running');
};

# make sure unrelated jobs are not cancelled
$ret = $t->get_ok("/api/v1/jobs/$clone99981")->status_is(200);
is($ret->tx->res->json->{job}->{state}, 'scheduled', "job $clone99981 is still scheduled");

# ... and we have a new test
$ret = $t->get_ok("/api/v1/jobs/$newid")->status_is(200);
is($ret->tx->res->json->{job}->{state}, 'scheduled', "new job $newid is scheduled");

# cancel the iso
$ret = $t->post_ok("/api/v1/isos/$iso/cancel")->status_is(200);

$ret = $t->get_ok("/api/v1/jobs/$newid")->status_is(200);
is($ret->tx->res->json->{job}->{state}, 'cancelled', "job $newid is cancelled");

# make sure we can't post invalid parameters
$res = schedule_iso({iso => $iso, tests => "kde/usb"}, 400);

# handle list of tests
$res = schedule_iso(
    {
        ISO     => $iso,
        DISTRI  => 'opensuse',
        VERSION => '13.1',
        FLAVOR  => 'DVD',
        ARCH    => 'i586',
        TEST    => 'server,kde,textmode',
        BUILD   => '0091'
    },
    200
);

is($res->json->{count}, 5, '5 new jobs created (two twice for both machine types)');

# delete the iso
# can not do as operator
$ret = $t->delete_ok("/api/v1/isos/$iso")->status_is(403);
# switch to admin and continue
$app = $t->app;
$t->ua(OpenQA::Client->new(apikey => 'ARTHURKEY01', apisecret => 'EXCALIBUR')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);
$ret = $t->delete_ok("/api/v1/isos/$iso")->status_is(200);
# now the jobs should be gone
$ret = $t->get_ok('/api/v1/jobs/$newid')->status_is(404);

subtest 'jobs belonging to important builds are not cancelled by new iso post' => sub {
    $ret = $t->get_ok('/api/v1/jobs/99963')->status_is(200);
    is($ret->tx->res->json->{job}->{state}, 'running', 'job in build 0091 running');
    my $tag = 'tag:0091:important';
    $t->app->db->resultset("JobGroups")->find(1001)->comments->create({text => $tag, user_id => 99901});
    $res = schedule_iso(
        {ISO => $iso, DISTRI => 'opensuse', VERSION => '13.1', FLAVOR => 'DVD', ARCH => 'i586', BUILD => '0091'});
    is($res->json->{count}, 10, '10 jobs created');
    my $example = $res->json->{ids}->[9];
    $ret = $t->get_ok("/api/v1/jobs/$example")->status_is(200);
    is($ret->tx->res->json->{job}->{state}, 'scheduled');
    $res = schedule_iso(
        {ISO => $iso, DISTRI => 'opensuse', VERSION => '13.1', FLAVOR => 'DVD', ARCH => 'i586', BUILD => '0092'});
    $ret = $t->get_ok("/api/v1/jobs/$example")->status_is(200);
    is($ret->tx->res->json->{job}->{state}, 'scheduled', 'job in old important build still scheduled');
    $res = schedule_iso(
        {ISO => $iso, DISTRI => 'opensuse', VERSION => '13.1', FLAVOR => 'DVD', ARCH => 'i586', BUILD => '0093'});
    $ret = $t->get_ok('/api/v1/jobs?state=scheduled');
    my @jobs = @{$ret->tx->res->json->{jobs}};
    lj;
    ok(!grep({ $_->{settings}->{BUILD} =~ '009[2]' } @jobs), 'no jobs from intermediate, not-important build');
    is(scalar @jobs, 21, 'only the important jobs, jobs from the current build and the important build are scheduled');
    # now test with a VERSION-BUILD format tag
    $tag = 'tag:13.1-0093:important';
    $t->app->db->resultset("JobGroups")->find(1001)->comments->create({text => $tag, user_id => 99901});
    $res = schedule_iso(
        {ISO => $iso, DISTRI => 'opensuse', VERSION => '13.1', FLAVOR => 'DVD', ARCH => 'i586', BUILD => '0094'});
    $ret  = $t->get_ok('/api/v1/jobs?state=scheduled');
    @jobs = @{$ret->tx->res->json->{jobs}};
    lj;
    ok(grep({ $_->{settings}->{BUILD} eq '0091' } @jobs), 'we have jobs from important build 0091');
    ok(grep({ $_->{settings}->{BUILD} eq '0093' } @jobs), 'we have jobs from important build 0093');
    is(scalar @jobs, 31, 'only the important jobs, jobs from the current build and the important builds are scheduled');
};

subtest 'build obsoletion/depriorization' => sub {
    my %iso = (ISO => $iso, DISTRI => 'opensuse', VERSION => '13.1', FLAVOR => 'DVD', ARCH => 'i586', BUILD => '0095');
    $res = schedule_iso({%iso, BUILD => '0095'});
    $ret = $t->get_ok('/api/v1/jobs?state=scheduled')->status_is(200);
    my @jobs = @{$ret->tx->res->json->{jobs}};
    lj;
    ok(!grep({ $_->{settings}->{BUILD} =~ '009[24]' } @jobs), 'recent non-important builds were obsoleted');
    is(scalar @jobs, 31, 'current build and the important build are scheduled');
    $res  = schedule_iso({%iso, BUILD => '0096', '_NO_OBSOLETE' => 1});
    $ret  = $t->get_ok('/api/v1/jobs?state=scheduled')->status_is(200);
    @jobs = @{$ret->tx->res->json->{jobs}};
    lj;
    my @jobs_previous_build = grep { $_->{settings}->{BUILD} eq '0095' } @jobs;
    ok(@jobs_previous_build, 'previous build was not obsoleted');
    is($jobs_previous_build[0]->{priority}, 40, 'job is at same priority as before');
    is($jobs_previous_build[1]->{priority}, 40, 'second job, same priority');
    # set one job to already highest allowed
    $ret = $t->put_ok('/api/v1/jobs/' . $jobs_previous_build[1]->{id}, json => {priority => 100})->status_is(200);
    my $job_at_prio_limit = $ret->tx->res->json->{job_id};
    $res  = schedule_iso({%iso, BUILD => '0097', '_DEPRIORITIZEBUILD' => 1});
    $ret  = $t->get_ok('/api/v1/jobs?state=scheduled')->status_is(200);
    @jobs = @{$ret->tx->res->json->{jobs}};
    lj;
    @jobs_previous_build = grep { $_->{settings}->{BUILD} eq '0095' } @jobs;
    ok(@jobs_previous_build, 'old build still in progress');
    is($jobs_previous_build[0]->{priority}, 50, 'job of previous build is deprioritized');
    $t->get_ok('/api/v1/jobs/' . $job_at_prio_limit)->status_is(200);
    $t->json_is('/job/state' => 'cancelled', 'older job already at priorization limit was cancelled');
    # test 'only same build' obsoletion
    my @jobs_0097 = grep { $_->{settings}->{BUILD} eq '0097' } @jobs;
    $res  = schedule_iso({%iso, BUILD => '0097', '_ONLY_OBSOLETE_SAME_BUILD' => 1});
    $ret  = $t->get_ok('/api/v1/jobs?state=scheduled')->status_is(200);
    @jobs = @{$ret->tx->res->json->{jobs}};
    lj;
    # jobs from previous build shouldn't be cancelled
    @jobs_previous_build = grep { $_->{settings}->{BUILD} eq '0095' } @jobs;
    ok(@jobs_previous_build, 'old build still in progress');
    # previous 0097 jobs should be cancelled
    my $old0097job = $jobs_0097[0]->{id};
    $t->get_ok('/api/v1/jobs/' . $old0097job)->status_is(200);
    $t->json_is('/job/state' => 'cancelled', 'job from previous 0097 group was cancelled');
    # we should have new 0097 jobs
    @jobs_0097 = grep { $_->{settings}->{BUILD} eq '0097' } @jobs;
    ok(@jobs_0097, 'new jobs for 0097 were created');
};

$t->app->config->{global}->{download_domains} = 'localhost';

my $rsp;

# we keep checking gru task count and args over and over in this next bit,
# so let's not repeat the code over and over. If no 'expected args' are
# passed, just checks there are no download_asset tasks in the queue; if an
# array hash of 'expected args' is passed, checks there's one task in the
# queue and its args match the hash, then deletes it. $desc is appended to
# the test description so you know which one failed, if it fails.
sub check_download_asset {
    my ($desc, $expectargs) = @_;
    my $rs = $t->app->db->resultset("GruTasks")->search({taskname => 'download_asset'});
    if ($expectargs) {
        is($rs->count, 1, "gru task should be created: $desc");
        my $args = $rs->first->args;
        is_deeply($args, $expectargs, "download_asset task args should be as expected: $desc");
        $rs->first->delete;
    }
    else {
        is($rs->count, 0, "gru task should not be created: $desc");
    }
}

sub fetch_first_job {
    my ($t, $rsp) = @_;
    my $newid = $rsp->json->{ids}->[0];
    return $t->get_ok("/api/v1/jobs/$newid")->status_is(200)->tx->res->json->{job};
}

# Similarly for checking a setting in the created jobs...takes the app, the
# response object, the setting name, the expected value and the test
# description as args.
sub check_job_setting {
    my ($t, $rsp, $setting, $expected, $desc) = @_;
    my $ret = fetch_first_job($t, $rsp);
    is($ret->{settings}->{$setting}, $expected, $desc);
}

# Schedule download of an existing ISO
$rsp = schedule_iso(
    {
        DISTRI  => 'opensuse',
        VERSION => '13.1',
        FLAVOR  => 'DVD',
        ARCH    => 'i586',
        ISO_URL => 'http://localhost/openSUSE-13.1-DVD-i586-Build0091-Media.iso'
    });
check_download_asset('existing ISO');

# Schedule download of an existing HDD for extraction
$rsp = schedule_iso(
    {
        DISTRI               => 'opensuse',
        VERSION              => '13.1',
        FLAVOR               => 'DVD',
        ARCH                 => 'i586',
        HDD_1_DECOMPRESS_URL => 'http://localhost/openSUSE-13.1-x86_64.hda.xz'
    });
check_download_asset('existing HDD');

# Schedule download of a non-existing ISO
$rsp = schedule_iso(
    {
        DISTRI  => 'opensuse',
        VERSION => '13.1',
        FLAVOR  => 'DVD',
        ARCH    => 'i586',
        ISO_URL => 'http://localhost/nonexistent.iso'
    });
is($rsp->json->{count}, 10, 'a regular ISO post creates the expected number of jobs');
check_download_asset('non-existent ISO',
    ['http://localhost/nonexistent.iso', locate_asset('iso', 'nonexistent.iso', mustexist => 0), 0]);
check_job_setting($t, $rsp, 'ISO', 'nonexistent.iso', 'parameter ISO is correctly set from ISO_URL');

# Schedule download and uncompression of a non-existing HDD
$rsp = schedule_iso(
    {
        DISTRI               => 'opensuse',
        VERSION              => '13.1',
        FLAVOR               => 'DVD',
        ARCH                 => 'i586',
        HDD_1_DECOMPRESS_URL => 'http://localhost/nonexistent.hda.xz'
    });
is($rsp->json->{count}, 10, 'a regular ISO post creates the expected number of jobs');
check_download_asset('non-existent HDD (with uncompression)',
    ['http://localhost/nonexistent.hda.xz', locate_asset('hdd', 'nonexistent.hda', mustexist => 0), 1]);
check_job_setting($t, $rsp, 'HDD_1', 'nonexistent.hda', 'parameter HDD_1 is correctly set from HDD_1_DECOMPRESS_URL');

# Schedule download of a non-existing ISO with a custom target name
$rsp = schedule_iso(
    {
        DISTRI  => 'opensuse',
        VERSION => '13.1',
        FLAVOR  => 'DVD',
        ARCH    => 'i586',
        ISO_URL => 'http://localhost/nonexistent2.iso',
        ISO     => 'callitthis.iso'
    });
check_download_asset('non-existent ISO (with custom name)',
    ['http://localhost/nonexistent2.iso', locate_asset('iso', 'callitthis.iso', mustexist => 0), 0]);
check_job_setting($t, $rsp, 'ISO', 'callitthis.iso', 'parameter ISO is not overwritten when ISO_URL is set');

# Schedule download and uncompression of a non-existing kernel with a custom target name
$rsp = schedule_iso(
    {
        DISTRI                => 'opensuse',
        VERSION               => '13.1',
        FLAVOR                => 'DVD',
        ARCH                  => 'i586',
        KERNEL_DECOMPRESS_URL => 'http://localhost/nonexistvmlinuz',
        KERNEL                => 'callitvmlinuz'
    });
is($rsp->json->{count}, 10, 'a regular ISO post creates the expected number of jobs');
check_download_asset('non-existent kernel (with uncompression, custom name',
    ['http://localhost/nonexistvmlinuz', locate_asset('other', 'callitvmlinuz', mustexist => 0), 1]);
check_job_setting($t, $rsp, 'KERNEL', 'callitvmlinuz',
    'parameter KERNEL is not overwritten when KERNEL_DECOMPRESS_URL is set');

# Using non-asset _URL does not create gru job and schedule jobs
$rsp = schedule_iso(
    {
        DISTRI       => 'opensuse',
        VERSION      => '13.1',
        FLAVOR       => 'DVD',
        ARCH         => 'i586',
        NO_ASSET_URL => 'http://localhost/nonexistent.iso'
    });
is($rsp->json->{count}, 10, 'a regular ISO post creates the expected number of jobs');
check_download_asset('non-asset _URL');

# Using asset _URL but without filename extractable from URL create warning in log file, jobs, but no gru job
$rsp = schedule_iso(
    {DISTRI => 'opensuse', VERSION => '13.1', FLAVOR => 'DVD', ARCH => 'i586', ISO_URL => 'http://localhost'});
is($rsp->json->{count}, 10, 'a regular ISO post creates the expected number of jobs');
check_download_asset('asset _URL without valid filename');

# Using asset _URL outside of whitelist will yield 403
$rsp = schedule_iso(
    {
        DISTRI  => 'opensuse',
        VERSION => '13.1',
        FLAVOR  => 'DVD',
        ARCH    => 'i586',
        ISO_URL => 'http://adamshost/nonexistent.iso'
    },
    403
);
is($rsp->message, 'Asset download requested from non-whitelisted host adamshost');
check_download_asset('asset _URL not in whitelist');

# Using asset _DECOMPRESS_URL outside of whitelist will yield 403
$rsp = schedule_iso(
    {
        DISTRI               => 'opensuse',
        VERSION              => '13.1',
        FLAVOR               => 'DVD',
        ARCH                 => 'i586',
        HDD_1_DECOMPRESS_URL => 'http://adamshost/nonexistent.hda.xz'
    },
    403
);
is($rsp->message, 'Asset download requested from non-whitelisted host adamshost');
check_download_asset('asset _DECOMPRESS_URL not in whitelist');

# schedule an existant ISO against a repo to verify the ISO is registered and the repo is not
$rsp = schedule_iso(
    {
        DISTRI  => 'opensuse',
        VERSION => '13.1',
        FLAVOR  => 'DVD',
        ARCH    => 'i586',
        REPO_1  => 'http://open.qa/does-no-matter',
        ISO     => 'openSUSE-13.1-DVD-i586-Build0091-Media.iso'
    },
    200
);

is_deeply(
    fetch_first_job($t, $rsp)->{assets},
    {iso => ['openSUSE-13.1-DVD-i586-Build0091-Media.iso']},
    'ISO is scheduled'
);

done_testing();
