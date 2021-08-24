#!/usr/bin/env perl
# Copyright (C) 2014-2021 SUSE LLC
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
# with this program; if not, see <http://www.gnu.org/licenses/>.

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '300';
use OpenQA::Test::Case;
use OpenQA::Test::Client 'client';
use OpenQA::Test::Utils qw(assume_all_assets_exist perform_minion_jobs);
use OpenQA::Schema::Result::ScheduledProducts;
use Mojo::IOLoop;

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 03-users.pl 04-products.pl');
my $t = client(Test::Mojo->new('OpenQA::WebAPI'));

my $schema             = $t->app->schema;
my $job_templates      = $schema->resultset('JobTemplates');
my $test_suites        = $schema->resultset('TestSuites');
my $jobs               = $schema->resultset('Jobs');
my $scheduled_products = $schema->resultset('ScheduledProducts');
my $gru_tasks          = $schema->resultset('GruTasks');
assume_all_assets_exist;

sub lj {
    return unless $ENV{HARNESS_IS_VERBOSE};
    $t->get_ok('/api/v1/jobs')->status_is(200);
    my @jobs = @{$t->tx->res->json->{jobs}};
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
    my ($args, $status, $query_params, $msg) = @_;
    $status       //= 200;
    $query_params //= {};
    $msg          //= undef;

    my $url = Mojo::URL->new('/api/v1/isos');
    $url->query($query_params);

    $t->post_ok($url, form => $args)->status_is($status, $msg);
    return $t->tx->res;
}

my $iso = 'openSUSE-13.1-DVD-i586-Build0091-Media.iso';
my %iso = (ISO => $iso, DISTRI => 'opensuse', VERSION => '13.1', FLAVOR => 'DVD', ARCH => 'i586', BUILD => '0091');

$t->get_ok('/api/v1/jobs/99927')->status_is(200);
is($t->tx->res->json->{job}->{state}, 'scheduled', 'job 99927 is scheduled');
$t->get_ok('/api/v1/jobs/99928')->status_is(200);
is($t->tx->res->json->{job}->{state}, 'scheduled', 'job 99928 is scheduled');
$t->get_ok('/api/v1/jobs/99963')->status_is(200);
is($t->tx->res->json->{job}->{state}, 'running', 'job 99963 is running');

$t->get_ok('/api/v1/jobs/99981')->status_is(200);
is($t->tx->res->json->{job}->{state}, 'cancelled', 'job 99981 is cancelled');

$t->post_ok('/api/v1/jobs/99981/restart')->status_is(200);

$t->get_ok('/api/v1/jobs/99981')->status_is(200);
my $clone99981 = $t->tx->res->json->{job}->{clone_id};

$t->get_ok("/api/v1/jobs/$clone99981")->status_is(200);
is($t->tx->res->json->{job}->{state}, 'scheduled', 'job $clone99981 is scheduled');

lj;

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

    my $res = schedule_iso({%iso, PRECEDENCE => 'original', _GROUP => 'invalid group name'});
    is($res->json->{count}, 0, 'no jobs created if group invalid');

    $res = schedule_iso({%iso, PRECEDENCE => 'original', _GROUP => 'opensuse test'});
    is($res->json->{count},                           1,  'only one job created due to group filter');
    is($jobs->find($res->json->{ids}->[0])->priority, 42, 'prio from job template used');

    $res = schedule_iso(
        {
            %iso,
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
    ok(my $scheduled_job    = $jobs->find($scheduled_job_id),               'job actually scheduled');
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
$job_templates->find(
    {
        machine_id    => $schema->resultset('Machines')->find({name => '64bit'})->id,
        test_suite_id => $test_suites->find({name => 'server'})->id,
    })->update({prio => undef});

# schedule the iso, this should not actually be possible. Only isos
# with different name should result in new tests...
my $res = schedule_iso({%iso, PRECEDENCE => 'original', _OBSOLETE => '1'});

is($res->json->{count}, 10, '10 new jobs created');

my @newids = @{$res->json->{ids}};
my $newid  = $newids[0];

$t->get_ok('/api/v1/jobs');
my @jobs = @{$t->tx->res->json->{jobs}};

my $server_32       = find_job(\@jobs, \@newids, 'server',       '32bit');
my $client1_32      = find_job(\@jobs, \@newids, 'client1',      '32bit');
my $client2_32      = find_job(\@jobs, \@newids, 'client2',      '32bit');
my $advanced_kde_32 = find_job(\@jobs, \@newids, 'advanced_kde', '32bit');
my $kde_32          = find_job(\@jobs, \@newids, 'kde',          '32bit');
my $textmode_32     = find_job(\@jobs, \@newids, 'textmode',     '32bit');

is_deeply(
    $client1_32->{parents},
    {Parallel => [$server_32->{id}], Chained => [], 'Directly chained' => []},
    "server_32 is only parent of client1_32"
);
is_deeply(
    $client2_32->{parents},
    {Parallel => [$server_32->{id}], Chained => [], 'Directly chained' => []},
    "server_32 is only parent of client2_32"
);
is_deeply($server_32->{parents}, {Parallel => [], Chained => [], 'Directly chained' => []}, "server_32 has no parents");
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
    {Parallel => [$server_64->{id}], Chained => [], 'Directly chained' => []},
    "server_64 is only parent of client1_64"
);
is_deeply(
    $client2_64->{parents},
    {Parallel => [$server_64->{id}], Chained => [], 'Directly chained' => []},
    "server_64 is only parent of client2_64"
);
is_deeply($server_64->{parents}, {Parallel => [], Chained => [], 'Directly chained' => []}, "server_64 has no parents");
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
        WORKER_CLASS     => 'qemu_i586',
        TEST_SUITE_NAME  => 'advanced_kde'
    },
    'settings assigned as expected, variable expansion applied, taking job template settings into account'
) or diag explain $advanced_kde_64->{settings};

# variable precedence
is($client1_32->{settings}->{PRECEDENCE}, 'original',  "default precedence (post PRECEDENCE beats suite PRECEDENCE)");
is($client1_64->{settings}->{PRECEDENCE}, 'original',  "default precedence (post PRECEDENCE beats suite PRECEDENCE)");
is($server_32->{settings}->{PRECEDENCE}, 'overridden', "precedence override (suite +PRECEDENCE beats post PRECEDENCE)");
is($server_64->{settings}->{PRECEDENCE}, 'overridden', "precedence override (suite +PRECEDENCE beats post PRECEDENCE)");

lj;

subtest 'old tests are cancelled unless they are marked as important' => sub {
    $t->get_ok('/api/v1/jobs/99927')->status_is(200);
    is($t->tx->res->json->{job}->{state}, 'cancelled', 'job 99927 is cancelled');
    $t->get_ok('/api/v1/jobs/99928')->status_is(200);
    is($t->tx->res->json->{job}->{state}, 'scheduled', 'job 99928 is marked as important and therefore preserved');
    $t->get_ok('/api/v1/jobs/99963')->status_is(200);
    is($t->tx->res->json->{job}->{state}, 'running', 'job 99963 is running');
};

# make sure unrelated jobs are not cancelled
$t->get_ok("/api/v1/jobs/$clone99981")->status_is(200);
is($t->tx->res->json->{job}->{state}, 'scheduled', "job $clone99981 is still scheduled");

# ... and we have a new test
$t->get_ok("/api/v1/jobs/$newid")->status_is(200);
is($t->tx->res->json->{job}->{state}, 'scheduled', "new job $newid is scheduled");

# cancel the iso
$t->post_ok("/api/v1/isos/$iso/cancel")->status_is(200);

$t->get_ok("/api/v1/jobs/$newid")->status_is(200);
is($t->tx->res->json->{job}->{state}, 'cancelled', "job $newid is cancelled");

schedule_iso({iso => $iso, tests => "kde/usb"}, 400, {}, 'invalid parameters');
schedule_iso({%iso, FLAVOR    => 'cherry'}, 200, {}, 'no product found');
schedule_iso({%iso, _GROUP_ID => 12345},    404, {}, 'no templates found');

# handle list of tests
$res = schedule_iso({%iso, TEST => 'server,kde,textmode', _OBSOLETE => 1, _FORCE_OBSOLETE => 1}, 200);
is($res->json->{count}, 5, '5 new jobs created (two twice for both machine types)');

# delete the iso
# can not do as operator
$t->delete_ok("/api/v1/isos/$iso")->status_is(403);
# switch to admin and continue
client($t, apikey => 'ARTHURKEY01', apisecret => 'EXCALIBUR');
$t->delete_ok("/api/v1/isos/$iso")->status_is(200);
# now the jobs should be gone
$t->get_ok('/api/v1/jobs/$newid')->status_is(404);

subtest 'jobs belonging to important builds are not cancelled by new iso post' => sub {
    $t->get_ok('/api/v1/jobs/99963')->status_is(200);
    is($t->tx->res->json->{job}->{state}, 'running', 'job in build 0091 running');
    my $tag = 'tag:0091:important';
    $schema->resultset("JobGroups")->find(1001)->comments->create({text => $tag, user_id => 99901});
    $res = schedule_iso({%iso, _OBSOLETE => 1});
    is($res->json->{count}, 10, '10 jobs created');
    my $example = $res->json->{ids}->[9];
    $t->get_ok("/api/v1/jobs/$example")->status_is(200);
    is($t->tx->res->json->{job}->{state}, 'scheduled');
    $res = schedule_iso({%iso, BUILD => '0092', _OBSOLETE => 1});
    $t->get_ok("/api/v1/jobs/$example")->status_is(200);
    is($t->tx->res->json->{job}->{state}, 'scheduled', 'job in old important build still scheduled');
    $res = schedule_iso({%iso, BUILD => '0093', _OBSOLETE => 1});
    $t->get_ok('/api/v1/jobs?state=scheduled');
    my @jobs = @{$t->tx->res->json->{jobs}};
    lj;
    ok(!grep({ $_->{settings}->{BUILD} =~ '009[2]' } @jobs), 'no jobs from intermediate, not-important build');
    is(scalar @jobs, 21, 'only the important jobs, jobs from the current build and the important build are scheduled');
    # now test with a VERSION-BUILD format tag
    $tag = 'tag:13.1-0093:important';
    $schema->resultset("JobGroups")->find(1001)->comments->create({text => $tag, user_id => 99901});
    $res = schedule_iso({%iso, BUILD => '0094', _OBSOLETE => 1});
    $t->get_ok('/api/v1/jobs?state=scheduled');
    @jobs = @{$t->tx->res->json->{jobs}};
    lj;
    ok(grep({ $_->{settings}->{BUILD} eq '0091' } @jobs), 'we have jobs from important build 0091');
    ok(grep({ $_->{settings}->{BUILD} eq '0093' } @jobs), 'we have jobs from important build 0093');
    is(scalar @jobs, 31, 'only the important jobs, jobs from the current build and the important builds are scheduled');
};

subtest 'build obsoletion/depriorization' => sub {
    $res = schedule_iso({%iso, BUILD => '0095', _OBSOLETE => 1});
    $t->get_ok('/api/v1/jobs?state=scheduled')->status_is(200);
    my @jobs = @{$t->tx->res->json->{jobs}};
    lj;
    ok(!grep({ $_->{settings}->{BUILD} =~ '009[24]' } @jobs), 'recent non-important builds were obsoleted');
    is(scalar @jobs, 31, 'current build and the important build are scheduled');
    $res = schedule_iso({%iso, BUILD => '0096'});
    $t->get_ok('/api/v1/jobs?state=scheduled')->status_is(200);
    @jobs = @{$t->tx->res->json->{jobs}};
    lj;
    my @jobs_previous_build = grep { $_->{settings}->{BUILD} eq '0095' } @jobs;
    ok(@jobs_previous_build, 'previous build was not obsoleted');
    is($jobs_previous_build[0]->{priority}, 40, 'job is at same priority as before');
    is($jobs_previous_build[1]->{priority}, 40, 'second job, same priority');
    # set one job to already highest allowed
    $t->put_ok('/api/v1/jobs/' . $jobs_previous_build[1]->{id}, json => {priority => 100})->status_is(200);
    my $job_at_prio_limit = $t->tx->res->json->{job_id};
    $res = schedule_iso({%iso, BUILD => '0097', '_DEPRIORITIZEBUILD' => 1});
    $t->get_ok('/api/v1/jobs?state=scheduled')->status_is(200);
    @jobs = @{$t->tx->res->json->{jobs}};
    lj;
    @jobs_previous_build = grep { $_->{settings}->{BUILD} eq '0095' } @jobs;
    ok(@jobs_previous_build, 'old build still in progress');
    is($jobs_previous_build[0]->{priority}, 50, 'job of previous build is deprioritized');
    $t->get_ok('/api/v1/jobs/' . $job_at_prio_limit)->status_is(200);
    $t->json_is('/job/state' => 'cancelled', 'older job already at priorization limit was cancelled');
    # test 'only same build' obsoletion
    my @jobs_0097 = grep { $_->{settings}->{BUILD} eq '0097' } @jobs;
    $res = schedule_iso({%iso, BUILD => '0097', '_ONLY_OBSOLETE_SAME_BUILD' => 1, _OBSOLETE => 1});
    $t->get_ok('/api/v1/jobs?state=scheduled')->status_is(200);
    @jobs = @{$t->tx->res->json->{jobs}};
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

sub add_opensuse_test {
    my ($name, %settings) = @_;
    $settings{MACHINE} //= ['64bit'];
    my $job_template_name  = delete $settings{JOB_TEMPLATE_NAME};
    my $not_add_test_suite = delete $settings{NOT_ADD_TESTSUITE};
    my @mapped_settings;
    for my $key (keys %settings) {
        push(@mapped_settings, {key => $key, value => $settings{$key}}) if $key ne 'MACHINE';
    }
    $schema->resultset('TestSuites')->create(
        {
            name     => $name,
            settings => \@mapped_settings
        }) unless $not_add_test_suite;
    my $param = {
        test_suite => {name => $name},
        group_id   => 1002,
        product_id => 1
    };
    $param->{name} = $job_template_name if $job_template_name;
    for my $machine (@{$settings{MACHINE}}) {
        $param->{machine} = {name => $machine};
        $schema->resultset('JobTemplates')->create($param);
    }
}

subtest 'Catch multimachine cycles' => sub {

    # we want the data to be transient
    $schema->txn_begin;
    add_opensuse_test('Algol-a', PARALLEL_WITH => "Algol-b");
    add_opensuse_test('Algol-b', PARALLEL_WITH => "Algol-c");
    add_opensuse_test('Algol-c', PARALLEL_WITH => "Algol-a,Algol-b");

    my $res = schedule_iso({%iso, _GROUP => 'opensuse test'});
    is($res->json->{count}, 0, 'Cycle found');
    like(
        $res->json->{failed}->[0]->{error_messages}->[0],
        qr/There is a cycle in the dependencies of Algol-c/,
        "Cycle reported"
    );
    $schema->txn_rollback;
};

subtest 'Catch cycles in chained dependencies' => sub {
    $schema->txn_begin;
    add_opensuse_test('chained-a', START_AFTER_TEST          => 'chained-c');
    add_opensuse_test('chained-b', START_DIRECTLY_AFTER_TEST => 'chained-a');
    add_opensuse_test('chained-c', START_DIRECTLY_AFTER_TEST => 'chained-b');
    add_opensuse_test('chained-d', START_AFTER_TEST          => 'chained-c');

    my $res = schedule_iso({%iso, _GROUP => 'opensuse test'});
    is($res->json->{count}, 0, 'no jobs scheduled if cycle detected');
    like(
        $res->json->{failed}->[0]->{error_messages}->[0],
        qr/There is a cycle in the dependencies of chained-(a|b|c|d)/,
        'cycle reported'
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

    my $res = schedule_iso({%iso, _GROUP => 'opensuse test'});
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

subtest 'Handling different WORKER_CLASS in directly chained dependency chains' => sub {
    subtest 'different worker classes in distinct chains are accepted' => sub {
        $schema->txn_begin;
        add_opensuse_test('chained-a', WORKER_CLASS              => 'foo');
        add_opensuse_test('chained-b', START_DIRECTLY_AFTER_TEST => 'chained-a', WORKER_CLASS => 'foo');
        add_opensuse_test('chained-c', START_AFTER_TEST          => 'chained-b', WORKER_CLASS => 'bar');
        add_opensuse_test('chained-d', START_DIRECTLY_AFTER_TEST => 'chained-c', WORKER_CLASS => 'bar');
        add_opensuse_test('chained-e', START_DIRECTLY_AFTER_TEST => 'chained-d', WORKER_CLASS => 'bar');

        my $res = schedule_iso({%iso, _GROUP => 'opensuse test'});
        is($res->json->{count}, 5, 'all jobs scheduled');
        is_deeply($res->json->{failed}, [], 'no jobs failed') or diag explain $res->json->{failed};
        $schema->txn_rollback;
    };
    subtest 'different worker classes in the same direct chain are rejected' => sub {
        $schema->txn_begin;
        add_opensuse_test('chained-a', WORKER_CLASS              => 'foo');
        add_opensuse_test('chained-b', START_DIRECTLY_AFTER_TEST => 'chained-a', WORKER_CLASS => 'foo');
        add_opensuse_test('chained-c', START_DIRECTLY_AFTER_TEST => 'chained-b', WORKER_CLASS => 'bar');
        add_opensuse_test('chained-d', START_DIRECTLY_AFTER_TEST => 'chained-c', WORKER_CLASS => 'bar');
        add_opensuse_test('chained-e', START_DIRECTLY_AFTER_TEST => 'chained-d', WORKER_CLASS => 'bar');

        my $res = schedule_iso({%iso, _GROUP => 'opensuse test'});
        is($res->json->{count}, 0, 'none of the jobs has been scheduled');
        like(
            $_->{error_messages}->[0],
qr/Worker class of chained-(c|d|e) \(bar\) does not match the worker class of its directly chained parent \(foo\)/,
            'error reported'
        ) for @{$res->json->{failed}};
        $schema->txn_rollback;
    };
};

for my $machine_separator (qw(@ :)) {
    $schema->txn_begin;
    subtest "Create dependency for jobs on different machines"
      . " - dependency setting are correct (using machine separator '$machine_separator')" => sub {
        $t->post_ok('/api/v1/machines', form => {name => '64bit-ipmi', backend => 'ipmi', 'settings[TEST]' => 'ipmi'})
          ->status_is(200);
        add_opensuse_test('supportserver1');
        add_opensuse_test('supportserver2', MACHINE => ['64bit-ipmi']);
        add_opensuse_test(
            'client',
            PARALLEL_WITH => "supportserver1${machine_separator}64bit,supportserver2${machine_separator}64bit-ipmi",
            MACHINE       => ['Laptop_64']);

        add_opensuse_test('test1');
        add_opensuse_test('test2', MACHINE                   => ['64bit-ipmi']);
        add_opensuse_test('test3', START_AFTER_TEST          => "test1,test2${machine_separator}64bit-ipmi");
        add_opensuse_test('test4', START_DIRECTLY_AFTER_TEST => 'test3');

        my $res = schedule_iso({%iso, _GROUP => 'opensuse test'});
        is($res->json->{count}, 7, '7 jobs scheduled');
        my @newids = @{$res->json->{ids}};
        my $newid  = $newids[0];

        $t->get_ok('/api/v1/jobs');
        my @jobs = @{$t->tx->res->json->{jobs}};

        my $server1_64    = find_job(\@jobs, \@newids, 'supportserver1', '64bit');
        my $server2_ipmi  = find_job(\@jobs, \@newids, 'supportserver2', '64bit-ipmi');
        my $client_laptop = find_job(\@jobs, \@newids, 'client',         'Laptop_64');
        is_deeply(
            $client_laptop->{parents},
            {Parallel => [$server1_64->{id}, $server2_ipmi->{id}], Chained => [], 'Directly chained' => []},
            "server1_64 and server2_ipmi are the parents of client_laptop"
        );

        my $test1_64   = find_job(\@jobs, \@newids, 'test1', '64bit');
        my $test2_ipmi = find_job(\@jobs, \@newids, 'test2', '64bit-ipmi');
        my $test3_64   = find_job(\@jobs, \@newids, 'test3', '64bit');
        my $test4_64   = find_job(\@jobs, \@newids, 'test4', '64bit');
        is_deeply(
            $test3_64->{parents},
            {Parallel => [], Chained => [$test1_64->{id}, $test2_ipmi->{id}], 'Directly chained' => []},
            "test1_64 and test2_ipmi are the parents of test3"
        ) or diag explain $test3_64->{parents};
        is_deeply(
            $test4_64->{parents},
            {Parallel => [], Chained => [], 'Directly chained' => [$test3_64->{id}]},
            "test1_64 and test2_ipmi are the parents of test3"
        ) or diag explain $test4_64->{parents};

      };
    $schema->txn_rollback;
}

subtest 'Create dependency for jobs on different machines - best match and log error dependency' => sub {
    $schema->txn_begin;
    $t->post_ok('/api/v1/machines', form => {name => 'powerpc', backend => 'qemu', 'settings[TEST]' => 'power'})
      ->status_is(200);

    add_opensuse_test('install_ltp', MACHINE => ['powerpc']);
    add_opensuse_test('use_ltp', START_AFTER_TEST => 'install_ltp', MACHINE => ['powerpc', '64bit']);

    add_opensuse_test('install_kde', MACHINE => ['powerpc', '64bit']);
    add_opensuse_test('use_kde', START_AFTER_TEST => 'install_kde', MACHINE => ['powerpc', '64bit']);

    my $res = schedule_iso({%iso, _GROUP => 'opensuse test'});
    is($res->json->{count}, 6, '6 jobs scheduled');
    my @newids = @{$res->json->{ids}};
    my $newid  = $newids[0];

    $t->get_ok('/api/v1/jobs');
    my @jobs = @{$t->tx->res->json->{jobs}};

    my $install_ltp   = find_job(\@jobs, \@newids, 'install_ltp', 'powerpc');
    my $use_ltp_64    = find_job(\@jobs, \@newids, 'use_ltp',     '64bit');
    my $use_ltp_power = find_job(\@jobs, \@newids, 'use_ltp',     'powerpc');
    is_deeply($use_ltp_64->{parents}, undef, "not found parent for use_ltp on 64bit, check for dependency typos");
    like(
        $res->json->{failed}->[0]->{error_messages}->[0],
        qr/START_AFTER_TEST=install_ltp\@64bit not found - check for dependency typos and dependency cycles/,
        "install_ltp@64bit not exist, check for dependency typos"
    );
    is_deeply(
        $use_ltp_power->{parents},
        {Parallel => [], Chained => [$install_ltp->{id}], 'Directly chained' => []},
        "install_ltp is parent of use_ltp_power"
    );

    my $install_kde_64    = find_job(\@jobs, \@newids, 'install_kde', '64bit');
    my $install_kde_power = find_job(\@jobs, \@newids, 'install_kde', 'powerpc');
    my $use_kde_64        = find_job(\@jobs, \@newids, 'use_kde',     '64bit');
    my $use_kde_power     = find_job(\@jobs, \@newids, 'use_kde',     'powerpc');
    is_deeply(
        $use_kde_64->{parents},
        {Parallel => [], Chained => [$install_kde_64->{id}], 'Directly chained' => []},
        "install_kde_64 is only parent of use_kde_64"
    );
    is_deeply(
        $use_kde_power->{parents},
        {Parallel => [], Chained => [$install_kde_power->{id}], 'Directly chained' => []},
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
    add_opensuse_test('supportserver', MACHINE       => ['ppc', '64bit', 's390x']);
    add_opensuse_test('server1',       PARALLEL_WITH => 'supportserver@ppc', MACHINE => ['ppc-6G']);
    add_opensuse_test('slave1',        PARALLEL_WITH => 'supportserver@ppc', MACHINE => ['ppc-1G']);
    add_opensuse_test('slave2',        PARALLEL_WITH => 'supportserver@ppc', MACHINE => ['ppc-2G']);

    my $res = schedule_iso({%iso, _GROUP => 'opensuse test'});
    is($res->json->{count}, 6, '6 jobs scheduled');
    my @newids = @{$res->json->{ids}};
    my $newid  = $newids[0];

    $t->get_ok('/api/v1/jobs');
    my @jobs = @{$t->tx->res->json->{jobs}};

    my $supportserver_ppc   = find_job(\@jobs, \@newids, 'supportserver', 'ppc');
    my $supportserver_64    = find_job(\@jobs, \@newids, 'supportserver', '64bit');
    my $supportserver_s390x = find_job(\@jobs, \@newids, 'supportserver', 's390x');
    my $server1_ppc         = find_job(\@jobs, \@newids, 'server1',       'ppc-6G');
    my $slave1_ppc          = find_job(\@jobs, \@newids, 'slave1',        'ppc-1G');
    my $slave2_ppc          = find_job(\@jobs, \@newids, 'slave2',        'ppc-2G');

    for my $c (my @children = ($server1_ppc, $slave1_ppc, $slave2_ppc)) {
        is_deeply(
            $c->{parents},
            {Parallel => [$supportserver_ppc->{id}], Chained => [], 'Directly chained' => []},
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
                    qr/supportserver@(.*?) has no child, check its machine placed or dependency setting typos/,
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

    my $res = schedule_iso({%iso, PRECEDENCE => 'original'});
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
    %iso,
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
    perform_minion_jobs($t->app->minion);
    $t->get_ok("/api/v1/isos/$scheduled_product_id?include_job_ids=1")->status_is(200);
    $json = $t->tx->res->json;
    my $ok = 1;
    is($json->{status}, OpenQA::Schema::Result::ScheduledProducts::SCHEDULED, 'scheduled product marked as scheduled')
      or $ok = 0;
    is(scalar @{$json->{job_ids}},                       10, '10 jobs scheduled')               or $ok = 0;
    is(scalar @{$json->{results}->{successful_job_ids}}, 10, 'all jobs successfully scheduled') or $ok = 0;
    is_deeply(
        $json->{results}->{failed_job_info}->[0]->{error_messages},
        ['textmode@32bit has no child, check its machine placed or dependency setting typos'],
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
    is_deeply($json->{settings}, \%scheduling_params, 'parameter identical to the original scheduled product');
};

subtest 'circular reference' => sub {
    $res = schedule_iso(
        {
            %iso,
            ISO      => 'openSUSE-13.1-DVD-i586-Build%BUILD%-Media.iso',
            TEST     => 'textmode',
            BUILD    => '%BUILD_HA%',
            BUILD_HA => '%BUILD%'
        },
        400
    );
    like($res->json->{error}, qr/The key (\w+) contains a circular reference, its value is %\w+%/,
        'circular reference');
};

subtest '_SKIP_CHAINED_DEPS prevents scheduling parent tests' => sub {
    $schema->txn_begin;

    add_opensuse_test('parent_test', MACHINE => ['64bit']);
    add_opensuse_test(
        'child_test_1',
        START_AFTER_TEST => 'parent_test',
        PARALLEL_WITH    => 'child_test_2',
        MACHINE          => ['64bit']);
    add_opensuse_test('child_test_2', START_AFTER_TEST => 'parent_test', MACHINE => ['64bit']);

    my $res = schedule_iso(
        {
            %iso,
            _GROUP             => 'opensuse test',
            TEST               => 'child_test_1',
            _SKIP_CHAINED_DEPS => 1,
        });
    is($res->json->{count}, 2, '2 jobs scheduled');

    my %create_jobs = map { $jobs->find($_)->settings_hash->{'TEST'} => 1 } @{$res->json->{ids}};
    is_deeply(\%create_jobs, {child_test_1 => 1, child_test_2 => 1}, "parent jobs not scheduled");
    $schema->txn_rollback;
};

subtest 'schedule tests correctly when changing TEST to job template name' => sub {
    $schema->txn_begin;
    add_opensuse_test('parent', JOB_TEMPLATE_NAME => 'parent_variant1');
    add_opensuse_test(
        'child',
        START_AFTER_TEST  => 'parent_variant1',
        JOB_TEMPLATE_NAME => 'child_variant1'
    );
    add_opensuse_test(
        'child',
        NOT_ADD_TESTSUITE => 1,
        START_AFTER_TEST  => 'parent',
        JOB_TEMPLATE_NAME => 'child_variant2'
    );

    add_opensuse_test('child_test', START_AFTER_TEST => 'parent',);
    my $res = schedule_iso({%iso, _GROUP_ID => '1002'});
    is($res->json->{count}, 3, '3 jobs scheduled');

    $res = schedule_iso({%iso, _GROUP_ID => '1002', TEST => 'child'});
    is($res->json->{count}, 0, 'there is no job template which is named child');

    $res = schedule_iso({%iso, _GROUP_ID => '1002', TEST => 'child_test'});
    my $failed_message = $res->json->{failed}->[0];
    is(
        $failed_message->{error_messages}->[0],
        'START_AFTER_TEST=parent@64bit not found - check for dependency typos and dependency cycles',
        'failed to schedule parent job'
    );
    like($failed_message->{job_id}, qr/\d+/, 'child_test was scheduled');

    $res = schedule_iso({%iso, _GROUP_ID => '1002', TEST => 'child_variant1'});
    is($res->json->{count}, 2, 'both child and parent jobs were triggered successfully');

    $res = schedule_iso({%iso, _GROUP_ID => '1002', TEST => 'child_variant1', _SKIP_CHAINED_DEPS => 1});
    is($res->json->{count}, 1, 'do not schedule parent job');

    add_opensuse_test('parallel_one', JOB_TEMPLATE_NAME => 'parallel_one_variant');
    add_opensuse_test('parallel_two', PARALLEL_WITH     => 'parallel_one',);
    $res            = schedule_iso({%iso, _GROUP_ID => '1002', TEST => 'parallel_two'});
    $failed_message = $res->json->{failed}->[0];
    is(
        $failed_message->{error_messages}->[0],
        'PARALLEL_WITH=parallel_one@64bit not found - check for dependency typos and dependency cycles',
        'failed to schedule parallel job'
    );
    like($failed_message->{job_id}, qr/\d+/, 'parallel_two was scheduled');

    add_opensuse_test('parallel_three', PARALLEL_WITH => 'parallel_one_variant',);
    $res = schedule_iso({%iso, _GROUP_ID => '1002', TEST => 'parallel_three'});
    is($res->json->{count}, 2, 'trigger parallel job successfully');

    $schema->txn_rollback;
};

subtest 'PUBLISH and STORE variables cannot include slashes' => sub {
    $schema->txn_begin;
    add_opensuse_test('parent');
    add_opensuse_test(
        'child1',
        START_AFTER_TEST    => 'parent',
        HDD_1               => 'foo/server@64bit.qcow2',
        PUBLISH_HDD_1       => 'foo/foo1@64bit.qcow2',
        FORCE_PUBLISH_HDD_1 => 'foo/foo1@64bit.qcow2',
        STORE_HDD_1         => 'foo/foo1@64bit.qcow2',
        PUBLISH_HDD_2       => 'foo/foo2@64bit.qcow2',
        FORCE_PUBLISH_HDD_2 => 'foo/foo2@64bit.qcow2',
        STORE_HDD_2         => 'foo/foo2@64bit.qcow2',
        PUBLISH_HDD_3       => 'foo/foo3@64bit.qcow2',
        FORCE_PUBLISH_HDD_3 => 'foo/foo3@64bit.qcow2',
        STORE_HDD_3         => 'foo/foo3@64bit.qcow2',
    );
    add_opensuse_test('child2', START_AFTER_TEST => 'parent');
    my $res = schedule_iso({%iso, _GROUP_ID => '1002', TEST => 'child1,child2'}, 200);
    is($res->json->{count},                   2,        'child2 and parent were scheduled');
    is($res->json->{failed}->[0]->{job_name}, 'child1', 'the test child1 was not scheduled');
    like(
        $res->json->{failed}->[0]->{error_message},
        qr/The (\S+,){8}\S+ cannot include \/ in value/,
        'the test is scheduled failed because of the invalid value'
    );
    $schema->txn_rollback;
};

subtest 'Expand specified variables when scheduling iso' => sub {
    $schema->txn_begin;
    add_opensuse_test(
        'foo',
        BUILD_HA            => '%BUILD%',
        BUILD_SDK           => '%BUILD_HA%',
        SHUTDOWN_NEEDS_AUTH => 1,
        HDD_1         => '%DISTRI%-%VERSION%-%ARCH%-%BUILD_SDK%@%MACHINE%-minimal_with_sdk%BUILD_SDK%_installed.qcow2',
        MACHINE       => ['32bit', '64bit'],
        YAML_SCHEDULE => '%TEST%@%MACHINE%-staging.yaml',
    );
    my $res = schedule_iso({%iso, _GROUP_ID => '1002', TEST => 'foo', BUILD => '176.6'}, 200);
    is($res->json->{count}, 2, 'two job templates were scheduled');

    $iso{DISTRI} = 'OPENSUSE';
    $res = schedule_iso({%iso, _GROUP_ID => '1002', BUILD => '176.6', MACHINE => '64bit'}, 200);
    is($res->json->{count}, 1, 'only the job template which machine is 64bit was scheduled');
    my $result = $jobs->find($res->json->{ids}->[0])->settings_hash;
    is(
        $result->{HDD_1},
        'opensuse-13.1-i586-176.6@64bit-minimal_with_sdk176.6_installed.qcow2',
        'the specified variables were expanded correctly'
    );
    is($result->{BACKEND},         'qemu',                   'the BACKEND was added to settings correctly');
    is($result->{YAML_SCHEDULE},   'foo@64bit-staging.yaml', 'the TEST was replaced correctly');
    is($result->{TEST_SUITE_NAME}, 'foo',                    'the TEST_SUITE_NAME was right');
    is($result->{JOB_DESCRIPTION}, undef,                    'There is no job description');
};

done_testing();
