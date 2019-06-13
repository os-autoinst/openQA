#! /usr/bin/perl

# Copyright (C) 2014-2019 SUSE LLC
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
}

use Mojo::Base -strict;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;
use OpenQA::Client;
use OpenQA::Schema::Result::ScheduledProducts;
use Mojo::IOLoop;

use OpenQA::Utils 'locate_asset';

OpenQA::Test::Case->new->init_data;

my $t = Test::Mojo->new('OpenQA::WebAPI');

# XXX: Test::Mojo loses it's app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(
    OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

my $schema             = $t->app->schema;
my $job_templates      = $schema->resultset('JobTemplates');
my $test_suites        = $schema->resultset('TestSuites');
my $jobs               = $schema->resultset('Jobs');
my $scheduled_products = $schema->resultset('ScheduledProducts');

sub lj {
    return unless $ENV{HARNESS_IS_VERBOSE};
    my $ret  = $t->get_ok('/api/v1/jobs')->status_is(200);
    my @jobs = @{$ret->tx->res->json->{jobs}};
    for my $j (@jobs) {
        printf "%d %-10s %s (%s)\n", $j->{id}, $j->{state}, $j->{name}, $j->{priority};
    }
}

sub job_state {
    my $job_id = shift;
    my $ret    = $t->get_ok("/api/v1/jobs/$job_id")->status_is(200);
    return $ret->tx->res->json->{job}->{state};
}

sub job_result {
    my $job_id = shift;
    my $ret    = $t->get_ok("/api/v1/jobs/$job_id")->status_is(200);
    return $ret->tx->res->json->{job}->{result};
}

sub job_gru {
    my $job_id = shift;
    return $t->app->schema->resultset("GruDependencies")->search({job_id => $job_id})->single->gru_task->id;
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
    my ($args, $status, $query_params) = @_;
    $status //= 200;

    my $url = Mojo::URL->new('/api/v1/isos');
    $url->query($query_params);

    my $ret = $t->post_ok($url, form => $args)->status_is($status);
    return $ret->tx->res;
}

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

my @tasks = $schema->resultset('GruTasks')->search({taskname => 'download_asset'});
is(scalar @tasks, 0, 'we have no gru download tasks to start with');

# add a random comment on a scheduled but not started job so that this one
# later on is found as important and handled accordingly
$jobs->find(99928)->comments->create({text => 'any text', user_id => 99901});

subtest 'group filter and priority override' => sub {
    # add a job template for group 1002
    my $job_template = $job_templates->create(
        {
            machine    => {name => '64bit'},
            test_suite => {name => 'textmode-2'},
            prio       => 42,
            group_id   => 1002,
            product_id => 1,
        });

    my $res = schedule_iso(
        {
            ISO        => $iso,
            DISTRI     => 'opensuse',
            VERSION    => '13.1',
            FLAVOR     => 'DVD',
            ARCH       => 'i586',
            BUILD      => '0091',
            PRECEDENCE => 'original',
            _GROUP     => 'invalid group name',
        });
    is($res->json->{count}, 0, 'no jobs created if group invalid');

    $res = schedule_iso(
        {
            ISO        => $iso,
            DISTRI     => 'opensuse',
            VERSION    => '13.1',
            FLAVOR     => 'DVD',
            ARCH       => 'i586',
            BUILD      => '0091',
            PRECEDENCE => 'original',
            _GROUP     => 'opensuse test',
        });
    is($res->json->{count},                           1,  'only one job created due to group filter');
    is($jobs->find($res->json->{ids}->[0])->priority, 42, 'prio from job template used');

    $res = schedule_iso(
        {
            ISO        => $iso,
            DISTRI     => 'opensuse',
            VERSION    => '13.1',
            FLAVOR     => 'DVD',
            ARCH       => 'i586',
            BUILD      => '0091',
            PRECEDENCE => 'original',
            _GROUP_ID  => '1002',
            _PRIORITY  => 43,
        });
    is($res->json->{count},                           1,  'only one job created due to group filter (by ID)');
    is($jobs->find($res->json->{ids}->[0])->priority, 43, 'prio overridden via _PRIORITY');

    # delete job template again so the remaining tests are unaffected
    $job_template->delete;
};

subtest 'scheduled products added' => sub {
    my @scheduled_products = $scheduled_products->all;
    is(scalar @scheduled_products, 3, 'exactly 3 products scheduled in previous subtest');

    for my $product (@scheduled_products) {
        my $product_id = $product->id;
        is($product->distri,       'opensuse',                                           "distri, $product_id");
        is($product->version,      '13.1',                                               "version, $product_id");
        is($product->flavor,       'DVD',                                                "flavor, $product_id");
        is($product->arch,         'i586',                                               "arch, $product_id");
        is($product->build,        '0091',                                               "build, $product_id");
        is($product->iso,          $iso,                                                 "iso, $product_id");
        is(ref $product->settings, 'HASH',                                               "settings, $product_id");
        is(ref $product->results,  'HASH',                                               "results, $product_id");
        is($product->status,       OpenQA::Schema::Result::ScheduledProducts::SCHEDULED, "status, $product_id");
    }

    my $empty_result = $scheduled_products[0]->results;
    is_deeply(
        $empty_result,
        {
            failed_job_info    => [],
            successful_job_ids => [],
        },
        'empty result stored correctly, 1'
    ) or diag explain $empty_result;

    my $product_1        = $scheduled_products[1];
    my $product_1_id     = $product_1->id;
    my $non_empty_result = $product_1->results;
    is(scalar @{$non_empty_result->{successful_job_ids}}, 1, 'successful job ID stored correctly, 2')
      or diag explain $non_empty_result;

    my $stored_settings   = $scheduled_products[1]->settings;
    my %expected_settings = (
        ISO        => $iso,
        DISTRI     => 'opensuse',
        VERSION    => '13.1',
        FLAVOR     => 'DVD',
        ARCH       => 'i586',
        BUILD      => '0091',
        PRECEDENCE => 'original',
        _GROUP     => 'opensuse test',
    );
    is_deeply($stored_settings, \%expected_settings, 'settings stored correctly, 3') or diag explain $stored_settings;

    ok(my $scheduled_job_id = $non_empty_result->{successful_job_ids}->[0], 'scheduled job ID present');
    ok(my $scheduled_job = $jobs->find($scheduled_job_id), 'job actually scheduled');
    is($scheduled_job->scheduled_product->id, $product_1_id, 'scheduled product assigned');
    is_deeply([map { $_->id } $product_1->jobs->all],
        [$scheduled_job_id], 'relationship works also the other way around');

    subtest 'api for querying scheduled products' => sub {
        $t->get_ok("/api/v1/isos/$product_1_id?include_job_ids=1")->status_is(200);
        my $json = $t->tx->res->json;

        ok(delete $json->{t_created}, 't_created exists');
        ok(delete $json->{t_updated}, 't_updated exists');
        is_deeply(
            $json,
            {
                id            => $product_1_id,
                gru_task_id   => undef,
                minion_job_id => undef,
                user_id       => 99903,
                job_ids       => [$scheduled_job_id],
                status        => 'scheduled',
                distri        => 'opensuse',
                version       => '13.1',
                flavor        => 'DVD',
                build         => '0091',
                arch          => 'i586',
                iso           => 'openSUSE-13.1-DVD-i586-Build0091-Media.iso',
                results       => {
                    failed_job_info    => [],
                    successful_job_ids => [$scheduled_job_id],
                },
                settings => \%expected_settings,
            },
            'scheduled product serialized as expected'
        ) or diag explain $json;
    };
};

# set prio of job template for $server_64 to undef so the prio is inherited from the job group
$job_templates->find(9)->update({prio => undef});

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
is($server_64->{priority}, 50,   'server_64 has default priority from job group');

is($advanced_kde_32->{settings}->{PUBLISH_HDD_1},
    undef, 'variable expansion because kde is not created for 32 bit machine');
is_deeply(
    $advanced_kde_64->{settings},
    {
        ADVANCED    => '1',
        ARCH        => 'i586',
        BACKEND     => 'qemu',
        BUILD       => '0091',
        DESKTOP     => 'advanced_kde',                                                # overridden on job template level
        DISTRI      => 'opensuse',
        DVD         => '1',
        FLAVOR      => 'DVD',
        ISO         => 'openSUSE-13.1-DVD-i586-Build0091-Media.iso',
        ISO_MAXSIZE => '4700372992',
        MACHINE     => '64bit',
        NAME        => '00099990-opensuse-13.1-DVD-i586-Build0091-advanced_kde@64bit',
        PRECEDENCE  => 'original',
        PUBLISH_HDD_1 => 'opensuse-13.1-i586-advanced_kde-qemu64.qcow2'
        ,    # variable expansion (using variable from job template level as well)
        QEMUCPU          => 'qemu64',
        START_AFTER_TEST => 'kde,textmode',
        TEST             => 'advanced_kde',
        VERSION          => '13.1',
        WORKER_CLASS     => 'qemu_i586'
    },
    'settings assigned as expected, variable expansion applied, taking job template settings into account'
) or diag explain $advanced_kde_64->{settings};

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
    $t->app->schema->resultset("JobGroups")->find(1001)->comments->create({text => $tag, user_id => 99901});
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
    $t->app->schema->resultset("JobGroups")->find(1001)->comments->create({text => $tag, user_id => 99901});
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
    my $rs = $t->app->schema->resultset("GruTasks")->search({taskname => 'download_asset'});
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
is($rsp->body, 'Asset download requested from non-whitelisted host adamshost.');
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
is($rsp->body, 'Asset download requested from non-whitelisted host adamshost.');
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

# Schedule an iso that triggers a gru that fails
$rsp = schedule_iso(
    {
        DISTRI  => 'opensuse',
        VERSION => '13.1',
        FLAVOR  => 'DVD',
        ARCH    => 'i586',
        ISO_URL => 'http://localhost/failure.iso'
    });
is $rsp->json->{count}, 10;
my $gru = job_gru($rsp->json->{ids}->[0]);

foreach my $j (@{$rsp->json->{ids}}) {
    is job_state($j), 'scheduled';
    is job_result($j), 'none', 'Job has no result';
}

$t->app->schema->resultset("GruTasks")->search({id => $gru})->single->fail;

foreach my $j (@{$rsp->json->{ids}}) {
    is job_state($j), 'done';
    like job_result($j), qr/incomplete|skipped/, 'Job skipped/incompleted';
}

sub add_opensuse_test {
    my ($name, %settings) = @_;
    $settings{MACHINE} //= ['64bit'];
    my @mapped_settings;
    for my $key (keys %settings) {
        push(@mapped_settings, {key => $key, value => $settings{$key}});
    }
    $t->app->schema->resultset('TestSuites')->create(
        {
            name     => $name,
            settings => \@mapped_settings
        });
    for my $machine (@{$settings{MACHINE}}) {
        $t->app->schema->resultset('JobTemplates')->create(
            {
                machine    => {name => $machine},
                test_suite => {name => $name},
                group_id   => 1002,
                product_id => 1,
            });
    }
}

subtest 'Catch multimachine cycles' => sub {

    # we want the data to be transient
    $schema->txn_begin;
    add_opensuse_test('Algol-a', PARALLEL_WITH => "Algol-b");
    add_opensuse_test('Algol-b', PARALLEL_WITH => "Algol-c");
    add_opensuse_test('Algol-c', PARALLEL_WITH => "Algol-a,Algol-b");

    my $res = schedule_iso(
        {
            ISO     => $iso,
            DISTRI  => 'opensuse',
            VERSION => '13.1',
            FLAVOR  => 'DVD',
            ARCH    => 'i586',
            BUILD   => '0091',
            _GROUP  => 'opensuse test',
        });

    is($res->json->{count}, 0, 'Cycle found');
    like(
        $res->json->{failed}->[0]->{error_messages}->[0],
        qr/There is a cycle in the dependencies of Algol-c/,
        "Cycle reported"
    );
    $schema->txn_rollback;
};

subtest 'Catch blocked_by cycles' => sub {

    # we want the data to be transient
    $schema->txn_begin;
    add_opensuse_test "ha_alpha_node01_upgrade";
    add_opensuse_test "ha_alpha_node02_upgrade";
    add_opensuse_test "ha_supportserver_upgraded";
    add_opensuse_test 'ha_alpha_node01_upgraded',
      PARALLEL_WITH    => 'ha_supportserver_upgraded',
      START_AFTER_TEST => 'ha_alpha_node01_upgrade';
    add_opensuse_test 'ha_alpha_node02_upgraded',
      PARALLEL_WITH    => 'ha_supportserver_upgraded',
      START_AFTER_TEST => 'ha_alpha_node02_upgrade';

    my $res = schedule_iso(
        {
            ISO     => $iso,
            DISTRI  => 'opensuse',
            VERSION => '13.1',
            FLAVOR  => 'DVD',
            ARCH    => 'i586',
            BUILD   => '0091',
            _GROUP  => 'opensuse test',
        });

    is($res->json->{count}, 5, 'All jobs scheduled');

    # this kind of functional test makes it a little harder to verify data
    my %block_hash;
    my %id_hash;
    for my $id (@{$res->json->{ids}}) {
        my $job = $schema->resultset('Jobs')->find($id)->to_hash;
        $block_hash{$job->{settings}->{TEST}} = $job->{blocked_by_id};
        $id_hash{$job->{id}} = $job->{settings}->{TEST};
    }
    for my $name (keys %block_hash) {
        $block_hash{$name} = $id_hash{$block_hash{$name} || ''};
    }
    is_deeply(
        \%block_hash,
        {
            ha_alpha_node01_upgrade   => undef,
            ha_alpha_node01_upgraded  => "ha_alpha_node01_upgrade",
            ha_alpha_node02_upgrade   => undef,
            ha_alpha_node02_upgraded  => "ha_alpha_node02_upgrade",
            ha_supportserver_upgraded => "ha_alpha_node01_upgrade",
        },
        "Upgrades not blocked"
    );

    $schema->txn_rollback;
};

subtest 'Create dependency for jobs on different machines - dependency setting are correct' => sub {
    $schema->txn_begin;
    $t->post_ok('/api/v1/machines', form => {name => '64bit-ipmi', backend => 'ipmi', 'settings[TEST]' => 'ipmi'})
      ->status_is(200);
    add_opensuse_test('supportserver1');
    add_opensuse_test('supportserver2', MACHINE => ['64bit-ipmi']);
    add_opensuse_test(
        'client',
        PARALLEL_WITH => 'supportserver1:64bit,supportserver2:64bit-ipmi',
        MACHINE       => ['Laptop_64']);

    add_opensuse_test('test1');
    add_opensuse_test('test2', MACHINE          => ['64bit-ipmi']);
    add_opensuse_test('test3', START_AFTER_TEST => 'test1,test2:64bit-ipmi');

    my $res = schedule_iso(
        {
            ISO     => $iso,
            DISTRI  => 'opensuse',
            VERSION => '13.1',
            FLAVOR  => 'DVD',
            ARCH    => 'i586',
            BUILD   => '0091',
            _GROUP  => 'opensuse test',
        });

    is($res->json->{count}, 6, '6 jobs scheduled');
    my @newids = @{$res->json->{ids}};
    my $newid  = $newids[0];

    $ret = $t->get_ok('/api/v1/jobs');
    my @jobs = @{$ret->tx->res->json->{jobs}};

    my $server1_64    = find_job(\@jobs, \@newids, 'supportserver1', '64bit');
    my $server2_ipmi  = find_job(\@jobs, \@newids, 'supportserver2', '64bit-ipmi');
    my $client_laptop = find_job(\@jobs, \@newids, 'client',         'Laptop_64');
    is_deeply(
        $client_laptop->{parents},
        {Parallel => [$server1_64->{id}, $server2_ipmi->{id}], Chained => []},
        "server1_64 and server2_ipmi are the parents of client_laptop"
    );

    my $test1_64   = find_job(\@jobs, \@newids, 'test1', '64bit');
    my $test2_ipmi = find_job(\@jobs, \@newids, 'test2', '64bit-ipmi');
    my $test3_64   = find_job(\@jobs, \@newids, 'test3', '64bit');
    is_deeply(
        $test3_64->{parents},
        {Parallel => [], Chained => [$test1_64->{id}, $test2_ipmi->{id}]},
        "test1_64 and test2_ipmi are the parents of test3"
    );

    $schema->txn_rollback;
};

subtest 'Create dependency for jobs on different machines - best match and log error dependency' => sub {
    $schema->txn_begin;
    $t->post_ok('/api/v1/machines', form => {name => 'powerpc', backend => 'qemu', 'settings[TEST]' => 'power'})
      ->status_is(200);

    add_opensuse_test('install_ltp', MACHINE => ['powerpc']);
    add_opensuse_test('use_ltp', START_AFTER_TEST => 'install_ltp', MACHINE => ['powerpc', '64bit']);

    add_opensuse_test('install_kde', MACHINE => ['powerpc', '64bit']);
    add_opensuse_test('use_kde', START_AFTER_TEST => 'install_kde', MACHINE => ['powerpc', '64bit']);

    my $res = schedule_iso(
        {
            ISO     => $iso,
            DISTRI  => 'opensuse',
            VERSION => '13.1',
            FLAVOR  => 'DVD',
            ARCH    => 'i586',
            BUILD   => '0091',
            _GROUP  => 'opensuse test',
        });

    is($res->json->{count}, 6, '6 jobs scheduled');
    my @newids = @{$res->json->{ids}};
    my $newid  = $newids[0];

    $ret = $t->get_ok('/api/v1/jobs');
    my @jobs = @{$ret->tx->res->json->{jobs}};

    my $install_ltp   = find_job(\@jobs, \@newids, 'install_ltp', 'powerpc');
    my $use_ltp_64    = find_job(\@jobs, \@newids, 'use_ltp',     '64bit');
    my $use_ltp_power = find_job(\@jobs, \@newids, 'use_ltp',     'powerpc');
    is_deeply($use_ltp_64->{parents}, undef, "not found parent for use_ltp on 64bit, check for dependency typos");
    like(
        $res->json->{failed}->[0]->{error_messages}->[0],
        qr/START_AFTER_TEST=install_ltp:64bit not found - check for dependency typos and dependency cycles/,
        "install_ltp:64bit not exist, check for dependency typos"
    );
    is_deeply(
        $use_ltp_power->{parents},
        {Parallel => [], Chained => [$install_ltp->{id}]},
        "install_ltp is parent of use_ltp_power"
    );

    my $install_kde_64    = find_job(\@jobs, \@newids, 'install_kde', '64bit');
    my $install_kde_power = find_job(\@jobs, \@newids, 'install_kde', 'powerpc');
    my $use_kde_64        = find_job(\@jobs, \@newids, 'use_kde',     '64bit');
    my $use_kde_power     = find_job(\@jobs, \@newids, 'use_kde',     'powerpc');
    is_deeply(
        $use_kde_64->{parents},
        {Parallel => [], Chained => [$install_kde_64->{id}]},
        "install_kde_64 is only parent of use_kde_64"
    );
    is_deeply(
        $use_kde_power->{parents},
        {Parallel => [], Chained => [$install_kde_power->{id}]},
        "install_kde_power is only parent of use_kde_power"
    );

    $schema->txn_rollback;
};

subtest 'Create dependency for jobs on different machines - log error parents' => sub {
    $schema->txn_begin;
    my @machines = qw(ppc ppc-6G ppc-1G ppc-2G s390x);
    for my $m (@machines) {
        $t->post_ok('/api/v1/machines', form => {name => $m, backend => 'qemu', 'settings[TEST]' => 'test'})
          ->status_is(200);
    }
    add_opensuse_test('supportserver', MACHINE => ['ppc', '64bit', 's390x']);
    add_opensuse_test('server1', PARALLEL_WITH => 'supportserver:ppc', MACHINE => ['ppc-6G']);
    add_opensuse_test('slave1',  PARALLEL_WITH => 'supportserver:ppc', MACHINE => ['ppc-1G']);
    add_opensuse_test('slave2',  PARALLEL_WITH => 'supportserver:ppc', MACHINE => ['ppc-2G']);

    my $res = schedule_iso(
        {
            ISO     => $iso,
            DISTRI  => 'opensuse',
            VERSION => '13.1',
            FLAVOR  => 'DVD',
            ARCH    => 'i586',
            BUILD   => '0091',
            _GROUP  => 'opensuse test',
        });

    is($res->json->{count}, 6, '6 jobs scheduled');
    my @newids = @{$res->json->{ids}};
    my $newid  = $newids[0];

    $ret = $t->get_ok('/api/v1/jobs');
    my @jobs = @{$ret->tx->res->json->{jobs}};

    my $supportserver_ppc   = find_job(\@jobs, \@newids, 'supportserver', 'ppc');
    my $supportserver_64    = find_job(\@jobs, \@newids, 'supportserver', '64bit');
    my $supportserver_s390x = find_job(\@jobs, \@newids, 'supportserver', 's390x');
    my $server1_ppc         = find_job(\@jobs, \@newids, 'server1',       'ppc-6G');
    my $slave1_ppc          = find_job(\@jobs, \@newids, 'slave1',        'ppc-1G');
    my $slave2_ppc          = find_job(\@jobs, \@newids, 'slave2',        'ppc-2G');

    for my $c (my @children = ($server1_ppc, $slave1_ppc, $slave2_ppc)) {
        is_deeply(
            $c->{parents},
            {Parallel => [$supportserver_ppc->{id}], Chained => []},
            "supportserver_ppc is only parent of " . $c->{name});
    }

    subtest 'error reported to client and logged in scheduled products table' => sub {
        for (0 .. 1) {
            my $json                     = $res->json;
            my $scheduled_product        = $scheduled_products->find($json->{scheduled_product_id});
            my $error_returned_to_client = $json->{failed}->[$_]->{error_messages}->[0];
            my $error_stored_in_scheduled_product
              = $scheduled_product->results->{failed_job_info}->[$_]->{error_messages}->[0];
            for my $error ($error_returned_to_client, $error_stored_in_scheduled_product) {
                like(
                    $error,
                    qr/supportserver:(.*?) has no child, check its machine placed or dependency setting typos/,
                    "supportserver placed on 64bit/s390x machine, but no child"
                );
            }
        }
    };

    $schema->txn_rollback;
};

subtest 'setting WORKER_CLASS and assigning default WORKER_CLASS' => sub {
    # assign a WORKER_CLASS to one of the testsuites
    my $worker_class                = 'advanced_worker';
    my $test_with_worker_class      = 'advanced_kde';
    my $testsuite_with_worker_class = $test_suites->find({name => $test_with_worker_class});
    $testsuite_with_worker_class->settings->create(
        {
            key   => 'WORKER_CLASS',
            value => $worker_class,
        });

    my $res = schedule_iso(
        {
            ISO        => $iso,
            DISTRI     => 'opensuse',
            VERSION    => '13.1',
            FLAVOR     => 'DVD',
            ARCH       => 'i586',
            BUILD      => '0091',
            PRECEDENCE => 'original',
        });
    is($res->json->{count}, 10, '10 jobs scheduled');

    # check whether the assignment of the WORKER_CLASS had effect and that all other jobs still have the default applied
    for my $job_id (@{$res->json->{ids}}) {
        my $job_settings        = $jobs->find($job_id)->settings_hash;
        my $test_name           = $job_settings->{TEST};
        my $actual_worker_class = $job_settings->{WORKER_CLASS};
        if ($test_name eq $test_with_worker_class) {
            is($actual_worker_class, $worker_class, "test $test_name with explicit WORKER_CLASS actually has it");
        }
        else {
            is($actual_worker_class, 'qemu_i586', "default WORKER_CLASS assigned to $test_name");
        }
    }
};

my $scheduled_product_id;
my %scheduling_params = (
    ISO        => $iso,
    DISTRI     => 'opensuse',
    VERSION    => '13.1',
    FLAVOR     => 'DVD',
    ARCH       => 'i586',
    BUILD      => '0091',
    PRECEDENCE => 'original',
    SPECIAL    => 'variable',
);

subtest 'async flag' => sub {
    # trigger scheduling using the same parameter as in previous subtests - just use the async flag this time
    my $res  = schedule_iso(\%scheduling_params, 200, {async => 1});
    my $json = $res->json;
    $scheduled_product_id = $json->{scheduled_product_id};
    ok($json->{gru_task_id},   'gru task ID returned');
    ok($json->{minion_job_id}, 'minion job ID returned');
    ok($scheduled_product_id,  'scheduled product ID returned');

    # verify that scheduled product has been added
    $t->get_ok("/api/v1/isos/$scheduled_product_id?include_job_ids=1")->status_is(200);
    $json = $t->tx->res->json;
    is($json->{status}, OpenQA::Schema::Result::ScheduledProducts::ADDED, 'scheduled product trackable');
    is_deeply($json->{settings}, \%scheduling_params, 'settings stored correctly');

    # run gru and check whether scheduled product has actually been scheduled
    $t->app->start('gru', 'run', '--oneshot');
    $t->get_ok("/api/v1/isos/$scheduled_product_id?include_job_ids=1")->status_is(200);
    $json = $t->tx->res->json;
    my $ok = 1;
    is($json->{status}, OpenQA::Schema::Result::ScheduledProducts::SCHEDULED, 'scheduled product marked as scheduled')
      or $ok = 0;
    is(scalar @{$json->{job_ids}}, 10, '10 jobs scheduled') or $ok = 0;
    is(scalar @{$json->{results}->{successful_job_ids}}, 10, 'all jobs sucessfully scheduled') or $ok = 0;
    is_deeply(
        $json->{results}->{failed_job_info}->[0]->{error_messages},
        ['textmode:32bit has no child, check its machine placed or dependency setting typos'],
        'there is one error message, though'
    ) or $ok = 0;
    diag explain $json unless $ok;

};

subtest 're-schedule product' => sub {
    plan skip_all => 'previous test "async flag" has not scheduled a product' unless $scheduled_product_id;

    my $res  = schedule_iso({scheduled_product_clone_id => $scheduled_product_id}, 200, {async => 1});
    my $json = $res->json;
    my $cloned_scheduled_product_id = $json->{scheduled_product_id};
    ok($cloned_scheduled_product_id, 'scheduled product ID returned');

    $t->get_ok("/api/v1/isos/$cloned_scheduled_product_id?include_job_ids=1")->status_is(200);
    $json = $t->tx->res->json;
    is($json->{status}, OpenQA::Schema::Result::ScheduledProducts::ADDED, 'scheduled product trackable');
    is_deeply($json->{settings}, \%scheduling_params, 'parameter idential to the original scheduled product');
};

done_testing();
