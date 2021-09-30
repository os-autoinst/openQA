#!/usr/bin/env perl
# Copyright 2014-2021 SUSE LLC
# Copyright 2016 Red Hat
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::TimeLimit '20';
use OpenQA::Test::Case;
use OpenQA::Test::Client 'client';
use Mojo::IOLoop;

use OpenQA::Utils 'locate_asset';

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 03-users.pl 04-products.pl');

my $t = client(Test::Mojo->new('OpenQA::WebAPI'));

my $gru_tasks = $t->app->schema->resultset('GruTasks');
my $gru_dependencies = $t->app->schema->resultset('GruDependencies');
my $test_suites = $t->app->schema->resultset('TestSuites');

sub schedule_iso {
    my ($args, $status, $query_params) = @_;
    $status //= 200;

    my $url = Mojo::URL->new('/api/v1/isos');
    $url->query($query_params);

    $t->post_ok($url, form => $args)->status_is($status);
    return $t->tx->res;
}

my $iso = 'openSUSE-13.1-DVD-i586-Build0091-Media.iso';
my %iso = (ISO => $iso, DISTRI => 'opensuse', VERSION => '13.1', FLAVOR => 'DVD', ARCH => 'i586', BUILD => '0091');

my @tasks = $gru_tasks->search({taskname => 'download_asset'});
is(scalar @tasks, 0, 'we have no gru download tasks to start with');
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
    my $rs = $gru_tasks->search({taskname => 'download_asset'});
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

sub get_job {
    my $jobid = shift;
    $t->get_ok("/api/v1/jobs/$jobid")->status_is(200)->tx->res->json->{job};
}

sub fetch_first_job {
    my ($t, $rsp) = @_;
    get_job($rsp->json->{ids}->[0]);
}

# Similarly for checking a setting in the created jobs...takes the app, the
# response object, the setting name, the expected value and the test
# description as args.
sub check_job_setting {
    my ($t, $rsp, $setting, $expected, $desc) = @_;
    my $ret = fetch_first_job($t, $rsp);
    is($ret->{settings}->{$setting}, $expected, $desc);
}

sub job_gru {
    my $job_id = shift;
    return $gru_dependencies->search({job_id => $job_id})->single->gru_task->id;
}

my $expected_job_count = 10;

# Schedule download of an existing ISO
$rsp = schedule_iso({%iso, ISO_URL => 'http://localhost/openSUSE-13.1-DVD-i586-Build0091-Media.iso'});
check_download_asset('existing ISO');

# Schedule download of an existing HDD for extraction
$rsp = schedule_iso({%iso, HDD_1_DECOMPRESS_URL => 'http://localhost/openSUSE-13.1-x86_64.hda.xz'});
check_download_asset('existing HDD');

# Schedule download of a non-existing ISO
my %params = (DISTRI => 'opensuse', VERSION => '13.1', FLAVOR => 'DVD', ARCH => 'i586');
$rsp = schedule_iso({%params, ISO_URL => 'http://localhost/nonexistent.iso'});
is($rsp->json->{count}, $expected_job_count, 'a regular ISO post creates the expected number of jobs');
check_download_asset('non-existent ISO',
    ['http://localhost/nonexistent.iso', [locate_asset('iso', 'nonexistent.iso', mustexist => 0)], 0]);
check_job_setting($t, $rsp, 'ISO', 'nonexistent.iso', 'parameter ISO is correctly set from ISO_URL');

# Schedule download and uncompression of a non-existing HDD
$rsp = schedule_iso({%iso, HDD_1_DECOMPRESS_URL => 'http://localhost/nonexistent.hda.xz'});
is($rsp->json->{count}, $expected_job_count, 'a regular ISO post creates the expected number of jobs');
check_download_asset('non-existent HDD (with uncompression)',
    ['http://localhost/nonexistent.hda.xz', [locate_asset('hdd', 'nonexistent.hda', mustexist => 0)], 1]);
check_job_setting($t, $rsp, 'HDD_1', 'nonexistent.hda', 'parameter HDD_1 correctly set from HDD_1_DECOMPRESS_URL');

# Schedule download of a non-existing ISO with a custom target name
$rsp = schedule_iso({%iso, ISO_URL => 'http://localhost/nonexistent2.iso', ISO => 'callitthis.iso'});
check_download_asset('non-existent ISO (with custom name)',
    ['http://localhost/nonexistent2.iso', [locate_asset('iso', 'callitthis.iso', mustexist => 0)], 0]);
check_job_setting($t, $rsp, 'ISO', 'callitthis.iso', 'parameter ISO is not overwritten when ISO_URL is set');

# Schedule download and uncompression of a non-existing kernel with a custom target name
$rsp = schedule_iso(
    {
        %params,
        KERNEL_DECOMPRESS_URL => 'http://localhost/nonexistvmlinuz',
        KERNEL => 'callitvmlinuz'
    });
is($rsp->json->{count}, $expected_job_count, 'a regular ISO post creates the expected number of jobs');
check_download_asset('non-existent kernel (with uncompression, custom name',
    ['http://localhost/nonexistvmlinuz', [locate_asset('other', 'callitvmlinuz', mustexist => 0)], 1]);
check_job_setting($t, $rsp, 'KERNEL', 'callitvmlinuz',
    'parameter KERNEL is not overwritten when KERNEL_DECOMPRESS_URL is set');

# Using non-asset _URL does not create gru job and schedule jobs
$rsp = schedule_iso({%params, NO_ASSET_URL => 'http://localhost/nonexistent.iso'});
is($rsp->json->{count}, $expected_job_count, 'a regular ISO post creates the expected number of jobs');
check_download_asset('non-asset _URL');
check_job_setting($t, $rsp, 'NO_ASSET', undef, 'NO_ASSET is not parsed from NO_ASSET_URL');

# Using asset _URL but without filename extractable from URL create warning in log file, jobs, but no gru job
$rsp = schedule_iso({%iso, ISO_URL => 'http://localhost'});
is($rsp->json->{count}, $expected_job_count, 'a regular ISO post creates the expected number of jobs');
check_download_asset('asset _URL without valid filename');

# Using asset _URL outside of passlist will yield 403
$rsp = schedule_iso({%iso, ISO_URL => 'http://adamshost/nonexistent.iso'}, 403);
is($rsp->body, 'Asset download requested from non-passlisted host adamshost.');
check_download_asset('asset _URL not in passlist');

# Using asset _DECOMPRESS_URL outside of passlist will yield 403
$rsp = schedule_iso({%params, HDD_1_DECOMPRESS_URL => 'http://adamshost/nonexistent.hda.xz'}, 403);
is($rsp->body, 'Asset download requested from non-passlisted host adamshost.');
check_download_asset('asset _DECOMPRESS_URL not in passlist');

# schedule an existent ISO against a repo to verify the ISO is registered and the repo is not
$rsp = schedule_iso({%iso, REPO_1 => 'http://open.qa/any-repo'}, 200);

is_deeply(
    fetch_first_job($t, $rsp)->{assets},
    {iso => ['openSUSE-13.1-DVD-i586-Build0091-Media.iso']},
    'ISO is scheduled'
);

# Schedule an iso that triggers a gru that fails
$rsp = schedule_iso({%params, ISO_URL => 'http://localhost/failure.iso'});
is $rsp->json->{count}, $expected_job_count;
my $gru = job_gru($rsp->json->{ids}->[0]);

foreach my $j (@{$rsp->json->{ids}}) {
    my $ret = get_job($j);
    is $ret->{state}, 'scheduled';
    is $ret->{result}, 'none', 'Job has no result';
}

$gru_tasks->search({id => $gru})->single->fail;

foreach my $j (@{$rsp->json->{ids}}) {
    my $ret = get_job($j);
    is $ret->{state}, 'done';
    like $ret->{result}, qr/incomplete|skipped/, 'Job skipped/incompleted';
}

sub get_gru_tasks {
    my $job_ids = shift;
    my %gru_task_ids;
    foreach my $job_id (@$job_ids) {
        my @gru_dependencies = $gru_dependencies->search({job_id => $job_id});
        foreach my $gru_dependency (@gru_dependencies) {
            my $gru_id = $gru_dependency->gru_task->id;
            if ($gru_task_ids{$gru_id}) {
                push @{$gru_task_ids{$gru_id}}, $job_id;
                next;
            }
            $gru_task_ids{$gru_id} = [$job_id];
        }
    }
    return \%gru_task_ids;
}

subtest 'handle _URL in job settings' => sub {
    $test_suites->find({name => 'kde'})->settings->create({key => 'HDD_1_URL', value => 'http://localhost/test.qcow2'});
    $rsp = schedule_iso({%iso, TEST => 'kde'}, 200);
    is $rsp->json->{count}, 1, 'one job was scheduled';
    $gru = job_gru($rsp->json->{ids}->[0]);
    check_download_asset('download asset when _URL in test suite settings',
        ['http://localhost/test.qcow2', [locate_asset('hdd', 'test.qcow2', mustexist => 0)], 0]);
};

subtest 'create one download task when there is HDD_1_URL in isos post command' => sub {
    $rsp = schedule_iso({%iso, HDD_1_URL => 'http://localhost/test.qcow2'}, 200);
    is $rsp->json->{count}, $expected_job_count, 'ten job were scheduled';
    my $gru_task_ids = get_gru_tasks($rsp->json->{ids});
    is scalar(keys %$gru_task_ids), 1, 'only one download task was created';
    my @value = values %$gru_task_ids;
    is scalar(@{$value[0]}), $expected_job_count, 'ten job were blocked by the same download task';
    check_download_asset('download asset was created',
        ['http://localhost/test.qcow2', [locate_asset('hdd', 'test.qcow2', mustexist => 0)], 0]);
};

subtest 'create many download tasks when many test suites have different _URL' => sub {
    $test_suites->find({name => 'textmode'})
      ->settings->create({key => 'HDD_1_URL', value => 'http://localhost/test_textmode.qcow2'});
    $test_suites->find({name => 'server'})
      ->settings->create({key => 'HDD_1_URL', value => 'http://localhost/test_server.qcow2'});
    $rsp = schedule_iso({%iso, MACHINE => '64bit'}, 200);
    is $rsp->json->{count}, 6, 'six jobs have been scheduled';
    my $gru_task_ids = get_gru_tasks($rsp->json->{ids});
    is scalar(keys %$gru_task_ids), 3, 'three download tasks were created';
    my $expected_download_tasks = {
        'http://localhost/test.qcow2' => [locate_asset('hdd', 'test.qcow2', mustexist => 0)],
        'http://localhost/test_textmode.qcow2' => [locate_asset('hdd', 'test_textmode.qcow2', mustexist => 0)],
        'http://localhost/test_server.qcow2' => [locate_asset('hdd', 'test_server.qcow2', mustexist => 0)],
    };
    is scalar(@$_), 1, 'the download task only blocks the related job' for (values %$gru_task_ids);
    my %created_download_tasks;
    foreach my $gru_id (keys %$gru_task_ids) {
        my $args = $gru_tasks->find($gru_id)->args;
        $created_download_tasks{$args->[0]} = $args->[1];
    }
    is_deeply \%created_download_tasks, $expected_download_tasks, 'the download tasks were created correctly';
};

subtest 'create one download task when test suites have different destinations' => sub {
    $test_suites->find({name => 'textmode'})->settings->create({key => 'HDD_1', value => 'test_textmode.qcow2'});
    $test_suites->find({name => 'server'})->settings->create({key => 'HDD_1', value => 'test_server.qcow2'});
    $test_suites->find({name => 'kde'})->settings->create({key => 'HDD_1', value => 'test_kde.qcow2'});
    $rsp = schedule_iso({%iso, HDD_1_URL => 'http://localhost/test.qcow2'}, 200);
    is $rsp->json->{count}, $expected_job_count, 'ten job was scheduled';
    my $gru_dep_tasks = get_gru_tasks($rsp->json->{ids});
    my @gru_task_ids = keys %$gru_dep_tasks;
    is scalar(@gru_task_ids), 1, 'only one download task was created';
    my $gru_task_id = $gru_task_ids[0];
    is scalar(@{$gru_dep_tasks->{$gru_task_id}}), 10, 'all jobs are blocked when specifying HDD_1_URL in command line';
    my $args = $gru_tasks->find($gru_task_id)->args;
    is $args->[0], 'http://localhost/test.qcow2', 'the url was correct';
    my @destinations = sort @{$args->[1]};
    is_deeply \@destinations,
      [
        locate_asset('hdd', 'test.qcow2', mustexist => 0),
        locate_asset('hdd', 'test_kde.qcow2', mustexist => 0),
        locate_asset('hdd', 'test_server.qcow2', mustexist => 0),
        locate_asset('hdd', 'test_textmode.qcow2', mustexist => 0)
      ],
      'one download task has 4 destinations';
};

subtest 'download task only blocks the related job when test suites have different destinations' => sub {
    $test_suites->find({name => $_})
      ->update_or_create_related('settings', {key => 'HDD_1_URL', value => 'http://localhost/test.qcow2'})
      for qw(textmode kde server);
    $rsp = schedule_iso({%iso, MACHINE => '64bit'}, 200);
    is $rsp->json->{count}, 6, 'six jobs have been scheduled';
    my $gru_dep_tasks = get_gru_tasks($rsp->json->{ids});
    my @gru_task_ids = keys %$gru_dep_tasks;
    is scalar(@gru_task_ids), 1, 'only one download task was created';
    is scalar(@{$gru_dep_tasks->{$gru_task_ids[0]}}), 3, 'one download task was created and it blocked 3 jobs';
};

subtest 'placeholder expansions work with _URL-derived settings' => sub {
    $test_suites->find({name => 'kde'})->settings->create({key => 'FOOBAR', value => '%ISO%'});
    my $new_params = {%params, ISO_URL => 'http://localhost/openSUSE-13.1-DVD-i586-Build0091-Media.iso', TEST => 'kde'};
    $rsp = schedule_iso($new_params, 200);
    is $rsp->json->{count}, 1, 'one job was scheduled';
    my $expanderjob = get_job($rsp->json->{ids}->[0]);
    is(
        $expanderjob->{settings}->{FOOBAR},
        'openSUSE-13.1-DVD-i586-Build0091-Media.iso',
        '%ISO% in template is expanded by posted ISO_URL'
    );
};

subtest 'test suite sets short asset setting to false value' => sub {
    $test_suites->find({name => 'kde'})->settings->create({key => 'ISO', value => ''});
    my $new_params = {%params, ISO_URL => 'http://localhost/openSUSE-13.1-DVD-i586-Build0091-Media.iso', TEST => 'kde'};
    $rsp = schedule_iso($new_params, 200);
    is $rsp->json->{count}, 1, 'one job was scheduled';
    my $overriddenjob = get_job($rsp->json->{ids}->[0]);
    is($overriddenjob->{settings}->{ISO}, '', 'false-evaluating ISO in template overrides posted ISO_URL');
};

done_testing();
