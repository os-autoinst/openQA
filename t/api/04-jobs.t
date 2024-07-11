#!/usr/bin/env perl

# Copyright 2015-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Mojo::Base -signatures;
use File::Temp;
use Test::Mojo;
use Test::Output;
use Test::Warnings ':report_warnings';
use Test::MockModule;
use OpenQA::Test::TimeLimit '30';
use OpenQA::Test::Utils 'mock_io_loop';
use OpenQA::App;
use OpenQA::Events;
use OpenQA::File;
use OpenQA::Parser 'parser';
use OpenQA::Test::Case;
use OpenQA::Test::Client 'client';
use OpenQA::Test::Utils 'perform_minion_jobs';
use OpenQA::Jobs::Constants;
use OpenQA::JobDependencies::Constants;
use OpenQA::Log 'log_debug';
use OpenQA::Script::CloneJob;
use OpenQA::Utils 'locate_asset';
use Mojo::IOLoop;
use Mojo::File qw(path tempfile tempdir);
use Digest::MD5;

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 02-workers.pl 03-users.pl 05-job_modules.pl');

# avoid polluting checkout
my $tempdir = tempdir("/tmp/$FindBin::Script-XXXX")->make_path;
$ENV{OPENQA_BASEDIR} = $tempdir;
note("OPENQA_BASEDIR: $tempdir");
path($tempdir, '/openqa/testresults')->make_path;
my $share_dir = path($tempdir, 'openqa/share')->make_path;
symlink "$FindBin::Bin/../data/openqa/share/factory", "$share_dir/factory";

# ensure job events are logged
$ENV{OPENQA_CONFIG} = $tempdir;
my @data = ("[audit]\n", "blocklist = job_grab\n");
$tempdir->child("openqa.ini")->spew(join '', @data);

my $chunk_size = 10000000;

my $io_loop_mock = mock_io_loop(subprocess => 1);

sub calculate_file_md5 ($file) {
    my $c = path($file)->slurp;
    my $md5 = Digest::MD5->new;
    $md5->add($c);
    return $md5->hexdigest;
}

# allow up to 200MB - videos mostly
$ENV{MOJO_MAX_MESSAGE_SIZE} = 207741824;

my $t = client(Test::Mojo->new('OpenQA::WebAPI'));
is($t->app->config->{audit}->{blocklist}, 'job_grab', 'blocklist updated');

my $schema = $t->app->schema;
my $assets = $schema->resultset('Assets');
my $jobs = $schema->resultset('Jobs');
my $products = $schema->resultset('Products');
my $testsuites = $schema->resultset('TestSuites');

$jobs->find($_)->register_assets_from_settings for 99939, 99946;
$assets->find({type => 'iso', name => 'openSUSE-Factory-staging_e-x86_64-Build87.5011-Media.iso'})->update({size => 0});
$jobs->find(99963)->update({assigned_worker_id => 1});

$t->get_ok('/api/v1/jobs')->status_is(200);
diag explain $t->tx->res->body unless $t->success;
exit unless $t->success;
my @jobs = @{$t->tx->res->json->{jobs}};
my $jobs_count = scalar @jobs;

subtest 'initial state of jobs listing' => sub {
    is($jobs_count, 18);
    my %jobs = map { $_->{id} => $_ } @jobs;
    is($jobs{99981}->{state}, 'cancelled');
    is($jobs{99981}->{origin_id}, undef, 'no original job');
    is($jobs{99981}->{assigned_worker_id}, undef, 'no worker assigned');
    is($jobs{99963}->{state}, 'running');
    is($jobs{99963}->{assigned_worker_id}, 1, 'worker 1 assigned');
    is($jobs{99927}->{state}, 'scheduled');
    is($jobs{99946}->{clone_id}, undef, 'no clone');
    is($jobs{99946}->{origin_id}, 99945, 'original job');
    is($jobs{99963}->{clone_id}, undef, 'no clone');
    is($jobs{99926}->{result}, INCOMPLETE, 'job is incomplete');
    is($jobs{99926}->{reason}, 'just a test', 'job has incomplete reason');
};

subtest 'only 9 are current and only 10 are relevant' => sub {
    $t->get_ok('/api/v1/jobs' => form => {scope => 'current'});
    is(scalar(@{$t->tx->res->json->{jobs}}), 15);
    $t->get_ok('/api/v1/jobs' => form => {scope => 'relevant'});
    is(scalar(@{$t->tx->res->json->{jobs}}), 16);
    $t->get_ok('/api/v1/jobs' => form => {latest => 1});
    is(scalar(@{$t->tx->res->json->{jobs}}), 15, 'Latest flag yields latest builds');
    for my $scope (qw(public private)) {
        $t->get_ok('/api/v1/jobs' => form => {scope => $scope})->status_is(400, "$scope is rejected")
          ->json_is('/error' => 'Erroneous parameters (scope invalid)', "$scope fails validation");
    }
};

subtest 'check limit quantity' => sub {
    $t->get_ok('/api/v1/jobs' => form => {scope => 'current', limit => 'foo'})->status_is(400)
      ->json_is({error => 'Erroneous parameters (limit invalid)', error_status => 400});
    $t->get_ok('/api/v1/jobs' => form => {scope => 'current', limit => 5})->status_is(200);
    is(scalar(@{$t->tx->res->json->{jobs}}), 5);
};

subtest 'check job group' => sub {
    $t->get_ok('/api/v1/jobs' => form => {scope => 'current', group => 'opensuse test'});
    is(scalar(@{$t->tx->res->json->{jobs}}), 1);
    is($t->tx->res->json->{jobs}->[0]->{id}, 99961);
    $t->get_ok('/api/v1/jobs' => form => {scope => 'current', group => 'foo bar'});
    is(scalar(@{$t->tx->res->json->{jobs}}), 0);
};

subtest 'restricted query' => sub {
    $t->get_ok('/api/v1/jobs?iso=openSUSE-13.1-DVD-i586-Build0091-Media.iso');
    is(scalar(@{$t->tx->res->json->{jobs}}), 6, 'query for existing jobs by iso');
    $t->get_ok('/api/v1/jobs?build=0091');
    is(scalar(@{$t->tx->res->json->{jobs}}), 11, 'query for existing jobs by build');
    $t->get_ok('/api/v1/jobs?hdd_1=openSUSE-13.1-x86_64.hda');
    is(scalar(@{$t->tx->res->json->{jobs}}), 3, 'query for existing jobs by hdd_1');
};

subtest 'argument combinations' => sub {
    $t->get_ok('/api/v1/jobs?test=kde');
    is(scalar(@{$t->tx->res->json->{jobs}}), 6);
    $t->get_ok('/api/v1/jobs?test=kde&result=passed');
    is(scalar(@{$t->tx->res->json->{jobs}}), 1);
    $t->get_ok('/api/v1/jobs?test=kde&result=softfailed');
    is(scalar(@{$t->tx->res->json->{jobs}}), 2);
    $t->get_ok('/api/v1/jobs?test=kde&result=softfailed&machine=64bit');
    is(scalar(@{$t->tx->res->json->{jobs}}), 1);
    $t->get_ok('/api/v1/jobs?test=kde&result=passed&machine=64bit');
    is(scalar(@{$t->tx->res->json->{jobs}}), 0);
};

subtest 'server-side limit with pagination' => sub {
    subtest 'input validation' => sub {
        $t->get_ok('/api/v1/jobs?limit=a')->status_is(400)
          ->json_is({error_status => 400, error => 'Erroneous parameters (limit invalid)'});
        $t->get_ok('/api/v1/jobs?offset=a')->status_is(400)
          ->json_is({error_status => 400, error => 'Erroneous parameters (offset invalid)'});
    };

    subtest 'navigation with limit' => sub {
        $t->get_ok('/api/v1/jobs?limit=5')->json_has('/jobs/4')->json_hasnt('/jobs/5');
        $t->get_ok('/api/v1/jobs?limit=1')->json_has('/jobs/0')->json_hasnt('/jobs/1')->json_is('/jobs/0/id' => 99981);

        $t->get_ok('/api/v1/jobs?limit=1&offset=1')->json_has('/jobs/0')->json_hasnt('/jobs/1')
          ->json_is('/jobs/0/id' => 99963);

        $t->get_ok('/api/v1/jobs?before=99928')->json_has('/jobs/3')->json_hasnt('/jobs/5');
        $t->get_ok('/api/v1/jobs?after=99945')->json_has('/jobs/5')->json_hasnt('/jobs/6');

        $t->get_ok('/api/v1/jobs?limit=18')->status_is(200);

        my $links;
        subtest 'first page' => sub {
            $t->get_ok('/api/v1/jobs?limit=5')->status_is(200)->json_is('/jobs/0/id' => 99947)
              ->json_is('/jobs/3/id' => 99963)->json_is('/jobs/4/id' => 99981)->json_hasnt('/jobs/5');
            $links = $t->tx->res->headers->links;
            ok $links->{first}, 'has first page';
            ok $links->{next}, 'has next page';
            ok !$links->{prev}, 'no previous page';
        };

        subtest 'second page' => sub {
            $t->get_ok($links->{next}{link})->status_is(200)->json_is('/jobs/0/id' => 99939)
              ->json_is('/jobs/3/id' => 99945)->json_is('/jobs/4/id' => 99946)->json_hasnt('/jobs/5');
            $links = $t->tx->res->headers->links;
            ok $links->{first}, 'has first page';
            ok $links->{next}, 'has next page';
            ok $links->{prev}, 'has previous page';
        };

        subtest 'third page' => sub {
            $t->get_ok($links->{next}{link})->status_is(200)->json_is('/jobs/0/id' => 99927)
              ->json_is('/jobs/3/id' => 99937)->json_is('/jobs/4/id' => 99938)->json_hasnt('/jobs/5');
            $links = $t->tx->res->headers->links;
            ok $links->{first}, 'has first page';
            ok $links->{next}, 'has next page';
            ok $links->{prev}, 'has previous page';
        };

        subtest 'first page (first link)' => sub {
            $t->get_ok($links->{first}{link})->status_is(200)->json_is('/jobs/0/id' => 99947)
              ->json_is('/jobs/3/id' => 99963)->json_is('/jobs/4/id' => 99981)->json_hasnt('/jobs/5');
            $links = $t->tx->res->headers->links;
            ok $links->{first}, 'has first page';
            ok $links->{next}, 'has next page link';
            ok !$links->{prev}, 'no previous page';
        };

        # The "latest=1" case is excluded from pagination since we have not found a good solution yet
        $t->get_ok('/api/v1/jobs?limit=18&latest=1')->status_is(200)->json_has('/jobs/2');
    };
};

subtest 'multiple ids' => sub {
    $t->get_ok('/api/v1/jobs?ids=99981,99963,99926');
    is(scalar(@{$t->tx->res->json->{jobs}}), 3);
    $t->get_ok('/api/v1/jobs?ids=99981&ids=99963&ids=99926');
    is(scalar(@{$t->tx->res->json->{jobs}}), 3);
};

subtest 'validation of IDs' => sub {
    $t->get_ok('/api/v1/jobs?ids=99981&ids=99963&ids=99926foo')->status_is(400);
    $t->json_is('/error', 'ids must be integers', 'validation error for IDs');
    $t->get_ok('/api/v1/jobs?groupid=foo')->status_is(400);
    $t->json_is('/error', 'Erroneous parameters (groupid invalid)', 'validation error for invalid group ID');
};

subtest 'job overview' => sub {
    # define expected jobs
    my %job_99940 = (id => 99940, name => 'opensuse-Factory-DVD-x86_64-Build0048@0815-doc@64bit');
    my %job_99939 = (id => 99939, name => 'opensuse-Factory-DVD-x86_64-Build0048-kde@64bit');
    my %job_99938 = (id => 99938, name => 'opensuse-Factory-DVD-x86_64-Build0048-doc@64bit');
    my %job_99936 = (id => 99936, name => 'opensuse-Factory-DVD-x86_64-Build0048-kde@64bit-uefi');
    my %job_99981 = (id => 99981, name => 'opensuse-13.1-GNOME-Live-i686-Build0091-RAID0@32bit');

    my $query = Mojo::URL->new('/api/v1/jobs/overview');

    subtest 'specific distri/version within job group' => sub {
        $query->query(distri => 'opensuse', version => 'Factory', groupid => '1001');
        $t->get_ok($query->path_query)->status_is(200);
        $t->json_is('' => [\%job_99940], 'latest build present');
    };

    subtest 'specific build without additional parameters' => sub {
        $query->query(build => '0048');
        $t->get_ok($query->path_query)->status_is(200);
        $t->json_is('' => [\%job_99939, \%job_99938, \%job_99936], 'latest build present');
    };

    subtest 'additional parameters' => sub {
        $query->query(build => '0048', machine => '64bit');
        $t->get_ok($query->path_query)->status_is(200);
        $t->json_is('' => [\%job_99939, \%job_99938], 'only 64-bit jobs present');
        $query->query(arch => 'i686');
        $t->get_ok($query->path_query)->status_is(200);
        $t->json_is('' => [\%job_99981], 'only i686 jobs present');
        $query->query(build => '0048', state => DONE, result => SOFTFAILED);
        $t->get_ok($query->path_query)->status_is(200);
        $t->json_is('' => [\%job_99939, \%job_99936], 'only softfailed jobs present');
    };

    subtest 'limit parameter' => sub {
        $query->query(build => '0048', limit => 1);
        $t->get_ok($query->path_query)->status_is(200);
        is(scalar(@{$t->tx->res->json}), 1, 'Expect only one job entry');
        $t->json_is('/0/id' => 99939, 'Check correct order');
    };
};

subtest 'jobs for job settings' => sub {
    $t->get_ok('/api/v1/job_settings/jobs' => form => {key => '*_TEST_ISSUES', list_value => 26102})->status_is(200)
      ->json_is({jobs => []});
    $t->get_ok('/api/v1/job_settings/jobs' => form => {key => '_TEST_ISSUES', list_value => 26103})->status_is(200)
      ->json_is({jobs => []});
    $t->get_ok('/api/v1/job_settings/jobs' => form => {key => '*_TEST_', list_value => 26103})->status_is(200)
      ->json_is({jobs => []});
    $t->get_ok('/api/v1/job_settings/jobs' => form => {key => '%test%', list_value => '%test%'})->status_is(400)
      ->json_is({error_status => 400, error => 'Erroneous parameters (key invalid, list_value invalid)'});

    $t->get_ok('/api/v1/job_settings/jobs' => form => {key => '*_TEST_ISSUES', list_value => 26103})->status_is(200)
      ->json_is({jobs => [99926]});
    $t->get_ok('/api/v1/job_settings/jobs' => form => {key => '*_TEST_ISSUES', list_value => 26104})->status_is(200)
      ->json_is({jobs => [99927]});
    $t->get_ok('/api/v1/job_settings/jobs' => form => {key => '*_TEST_ISSUES', list_value => 26105})->status_is(200)
      ->json_is({jobs => [99928, 99927]});
    $t->get_ok('/api/v1/job_settings/jobs' => form => {key => '*_TEST_ISSUES', list_value => 26106})->status_is(200)
      ->json_is({jobs => [99928, 99927]});
    $t->get_ok('/api/v1/job_settings/jobs' => form => {key => '*_TEST_ISSUES', list_value => 26110})->status_is(200)
      ->json_is({jobs => [99981]});

    $t->get_ok('/api/v1/job_settings/jobs' => form => {key => '*_TEST_ISSUES', list_value => 261042})->status_is(200)
      ->json_is({jobs => []});
    $t->get_ok('/api/v1/job_settings/jobs' => form => {key => '*_TEST_ISSUES', list_value => 2610})->status_is(200)
      ->json_is({jobs => []});
    $t->get_ok('/api/v1/job_settings/jobs' => form => {key => '*_TEST_ISSUES', list_value => 2})->status_is(200)
      ->json_is({jobs => []});

    local $t->app->config->{misc_limits}{job_settings_max_recent_jobs} = 5;
    $t->get_ok('/api/v1/job_settings/jobs' => form => {key => '*_TEST_ISSUES', list_value => 26110})->status_is(200)
      ->json_is({jobs => [99981]});
    $t->get_ok('/api/v1/job_settings/jobs' => form => {key => '*_TEST_ISSUES', list_value => 26103})->status_is(200)
      ->json_is({jobs => []});

    local $t->app->config->{misc_limits}{job_settings_max_recent_jobs} = 1000000000;
    $t->get_ok('/api/v1/job_settings/jobs' => form => {key => '*_TEST_ISSUES', list_value => 26110})->status_is(200)
      ->json_is({jobs => [99981]});
    $t->get_ok('/api/v1/job_settings/jobs' => form => {key => '*_TEST_ISSUES', list_value => 26103})->status_is(200)
      ->json_is({jobs => [99926]});
};

$schema->txn_begin;

subtest 'restart jobs, error handling' => sub {
    $t->post_ok('/api/v1/jobs/restart', form => {jobs => [99981, 99963, 99946, 99945, 99927, 99939]})->status_is(200);
    $t->json_is(
        '/errors/0' =>
          "Job 99939 misses the following mandatory assets: iso/openSUSE-Factory-DVD-x86_64-Build0048-Media.iso\n"
          . 'Ensure to provide mandatory assets and/or force retriggering if necessary.',
        'error for missing asset of 99939'
    );
    $t->json_is(
        '/errors/1' => 'Specified job 99945 has already been cloned as 99946',
        'error for 99945 being already cloned'
    );
};

$schema->txn_rollback;
$schema->txn_begin;

subtest 'prevent restarting parents' => sub {
    # turn parent of 99938 into a directly chained child
    my $job_dependencies = $schema->resultset('JobDependencies');
    $job_dependencies->create(
        {
            child_job_id => 99963,
            parent_job_id => 99961,
            dependency => OpenQA::JobDependencies::Constants::PARALLEL,
        });
    $job_dependencies->create(
        {
            child_job_id => 99938,
            parent_job_id => 99937,
            dependency => OpenQA::JobDependencies::Constants::DIRECTLY_CHAINED,
        });
    # restart the two jobs 99963 and 99938; one has a parallel parent (99961) and one a directly chained parent (99937)
    $t->post_ok('/api/v1/jobs/restart?force=1&skip_parents=1', form => {jobs => [99963, 99938]})->status_is(200);
    $t->json_is('/result' => [{99938 => 99985}, {99963 => 99986}], 'response')
      ->or(sub (@) { diag explain $t->tx->res->json });
    # check whether jobs have been restarted but not their parents
    isnt($jobs->find(99963)->clone_id, undef, 'job with parallel parent has been cloned');
    isnt($jobs->find(99938)->clone_id, undef, 'job with directly chained parent has been cloned');
    is($jobs->find(99961)->clone_id, undef, 'parallel parent has not been cloned');
    is($jobs->find(99937)->clone_id, undef, 'directly chained parent has not been cloned');
};

$schema->txn_rollback;

subtest 'restart jobs (forced)' => sub {
    $t->post_ok('/api/v1/jobs/restart?force=1', form => {jobs => [99981, 99963, 99946, 99945, 99927, 99939]})
      ->status_is(200);
    $t->json_is(
        '/warnings/0' =>
          "Job 99939 misses the following mandatory assets: iso/openSUSE-Factory-DVD-x86_64-Build0048-Media.iso\n"
          . 'Ensure to provide mandatory assets and/or force retriggering if necessary.',
        'warning for missing asset'
    );

    $t->get_ok('/api/v1/jobs');
    my @new_jobs = @{$t->tx->res->json->{jobs}};
    my %new_jobs = map { $_->{id} => $_ } @new_jobs;
    is $new_jobs{99981}->{state}, CANCELLED, 'running job has been cancelled';
    is $new_jobs{99927}->{state}, SCHEDULED, 'scheduled job is still scheduled';
    for my $orig_id (99939, 99946, 99963, 99981) {
        my $orig_job = $new_jobs{$orig_id};
        my $clone_id = $orig_job->{clone_id};
        next unless like $clone_id, qr/\d+/, "job $orig_id cloned";
        is $new_jobs{$clone_id}->{group_id}, $orig_job->{group_id}, "group of $orig_id taken over";
    }

    $t->get_ok('/api/v1/jobs' => form => {scope => 'current'});
    is(scalar(@{$t->tx->res->json->{jobs}}), 15, 'job count stay the same');
};

subtest 'restart single job passing settings' => sub {
    is($jobs->find(99926)->clone_id, undef, 'job has not been cloned yet');
    my $url = '/api/v1/jobs/99926/restart?';
    my $params = 'set=_GROUP%3D0&set=TEST%2B%3D%3Ainvestigate&set=ARCH%3Di386&set=FOO%3Dbar&set=FLAVOR%3D';
    $t->post_ok($url . 'set=_GROUP')->status_is(400, 'parameter without value does not pass validation');
    $t->post_ok($url . $params)->status_is(200);
    $t->json_is('/warnings' => undef, 'no warnings generated');
    $t->json_is('/errors' => undef, 'no errors generated');
    my $event = OpenQA::Test::Case::find_most_recent_event($schema, 'job_restart');
    is $event->{id}, 99926, 'restart produces event';
    my $clone = $jobs->find(99926)->clone;
    isnt $clone, undef, 'job has been cloned' or return;
    is $clone->group_id, undef, 'group has NOT been taken over due to _GROUP=0 parameter';
    is $clone->TEST, 'minimalx:investigate', 'appending to TEST variable via TEST+=:investigate parameter';
    is $clone->ARCH, 'i386', 'existing setting overridden via ARCH=i386 parameter';
    is $clone->FLAVOR, '', 'existing setting cleared via FLAVOR= parameter';
    is $clone->settings_hash->{FOO}, 'bar', 'new setting added via FOO=bar parameter';
    $jobs->find(80000)->update({group_id => 1002});
    $t->post_ok('/api/v1/jobs/restart?set=_GROUP_ID%3D0&prio=42&jobs=80000&clone=0')->status_is(200);
    my $restarted_id = [values %{($t->tx->res->json->{result} // [])->[0] // {}}]->[0];
    isnt $restarted_id, undef, 'job has been restarted' or diag explain $t->tx->res->json and return;
    is $jobs->find(80000)->clone_id, undef, '2nd job is not considered cloned' or return;
    my $restarted = $jobs->find($restarted_id);
    isnt $restarted_id, undef, 'restarted job actually present' or return;
    is $restarted->group_id, undef, 'group has NOT been taken over due to _GROUP_ID=0 parameter';
    is $restarted->priority, 42, 'prio set';
};

subtest 'duplicate route' => sub {
    $jobs->find(99939)->update({clone_id => undef});    # assume there's no clone yet
    $t->post_ok('/api/v1/jobs/99939/duplicate')->status_is(200);
    isnt(my $clone_id = $jobs->find(99939)->clone_id, undef, 'job has been cloned');
    $t->json_is('/id' => $clone_id, 'id of clone returned');
    $t->json_is('/result' => [{99939 => $clone_id}], 'mapping of original to clone job IDs returned');
    $t->json_like('/warnings/0' => qr/Job 99939 misses.*assets/, 'missing asset ignored by default with warning');
};

subtest 'parameter validation on artefact upload' => sub {
    $t->post_ok('/api/v1/jobs/99963/artefact?file=not-a-file&md5=not-an-md5sum&image=1')->status_is(400)->json_is(
        {
            error_status => 400,
            error => 'Erroneous parameters (file invalid, md5 invalid)',
        });
};

my $expected_result_size = 0;
my $rp;
my ($fh, $filename) = File::Temp::tempfile(UNLINK => 1);
seek($fh, 20 * 1024 * 1024, 0);    # create 200 MiB quick
syswrite($fh, "X");
close($fh);

subtest 'upload video' => sub {
    $rp = "$tempdir/openqa/testresults/00099/00099963-opensuse-13.1-DVD-x86_64-Build0091-kde/video.ogv";
    $t->post_ok('/api/v1/jobs/99963/artefact' => form => {file => {file => $filename, filename => 'video.ogv'}})
      ->status_is(200);

    ok(-e $rp, 'video exist after')
      and is($jobs->find(99963)->result_size, $expected_result_size += -s $rp, 'video size taken into account');
    is(calculate_file_md5($rp), 'feeebd34e507d3a1641c774da135be77', 'md5sum matches');
};

subtest 'upload "ulog" file' => sub {
    $rp = "$tempdir/openqa/testresults/00099/00099963-opensuse-13.1-DVD-x86_64-Build0091-kde/ulogs/y2logs.tar.bz2";
    $t->post_ok(
        '/api/v1/jobs/99963/artefact' => form => {file => {file => $filename, filename => 'y2logs.tar.bz2'}, ulog => 1})
      ->status_is(200);
    $t->content_is('OK');
    ok(-e $rp, 'logs exist after')
      and is($jobs->find(99963)->result_size, $expected_result_size += -s $rp, 'log size taken into account');
    is(calculate_file_md5($rp), 'feeebd34e507d3a1641c774da135be77', 'md5sum matches');
};

subtest 'upload screenshot' => sub {
    $rp = "$tempdir/openqa/images/347/da6/61d0c3faf37d49d33b6fc308f2.png";
    $t->post_ok(
        '/api/v1/jobs/99963/artefact?image=1&md5=347da661d0c3faf37d49d33b6fc308f2' => form => {
            file => {
                file => 't/images/347/da6/61d0c3faf37d49d33b6fc308f2.png',
                filename => 'foo.png'
            }})->status_is(200);
    $t->content_is('OK');
    ok(-e $rp, 'screenshot exists')
      and is($jobs->find(99963)->result_size, $expected_result_size += -s $rp, 'screenshot size taken into account');
    is(calculate_file_md5($rp), '347da661d0c3faf37d49d33b6fc308f2', 'md5sum matches');
};

subtest 'upload asset: fails without chunks' => sub {
    $rp = "$tempdir/openqa/share/factory/hdd/hdd_image.qcow2";
    $t->post_ok('/api/v1/jobs/99963/artefact' => form =>
          {file => {file => $filename, filename => 'hdd_image.qcow2'}, asset => 'public'})->status_is(500);
    $t->json_like('/error' => qr/Failed receiving asset/);
};

# prepare chunk upload
my $chunkdir = path("$tempdir/openqa/share/factory/tmp/public/00099963/hdd_image.qcow2.CHUNKS");
$chunkdir->remove_tree;

subtest 'upload asset: successful chunk upload' => sub {
    my $pieces = OpenQA::File->new(file => Mojo::File->new($filename))->split($chunk_size);
    $pieces->each(
        sub {
            $_->prepare;
            my $chunk_asset = Mojo::Asset::Memory->new->add_chunk($_->serialize);
            $t->post_ok('/api/v1/jobs/99963/artefact' => form =>
                  {file => {file => $chunk_asset, filename => 'hdd_image.qcow2'}, asset => 'public'})->status_is(200);
            $t->json_is({status => 'ok'});
            ok(-d $chunkdir, 'Chunk directory exists') unless $_->is_last;
            $_->content(\undef);
        });
    my $job = $jobs->find(99963);
    ok(!-d $chunkdir, 'Chunk directory should not exist anymore');
    ok(-e $rp, 'Asset exists after upload')
      and is($job->result_size, $expected_result_size, 'asset size not taken into account');
    $t->get_ok('/api/v1/assets/hdd/hdd_image.qcow2')->status_is(200)->json_is('/name' => 'hdd_image.qcow2');
    isnt $_->asset->size, undef, $_->asset->name . ' has known size' for $job->jobs_assets->all;
};

subtest 'Test failure - if chunks are broken' => sub {
    my $pieces = OpenQA::File->new(file => Mojo::File->new($filename))->split($chunk_size);
    $pieces->each(
        sub {
            $_->prepare;
            $_->content(int(rand(99999)));
            my $chunk_asset = Mojo::Asset::Memory->new->add_chunk($_->serialize);
            $t->post_ok('/api/v1/jobs/99963/artefact' => form =>
                  {file => {file => $chunk_asset, filename => 'hdd_image.qcow2'}, asset => 'public'});
            $t->json_like('/error' => qr/Can't verify written data from chunk/) unless $_->is_last();
            ok(!-d $chunkdir, 'Chunk directory does not exists') if $_->is_last;
            ok((-e path($chunkdir, 'hdd_image.qcow2')), 'Chunk is there') unless $_->is_last;
        });

    ok(!-d $chunkdir, 'Chunk directory does not exists - upload failed');
    $t->get_ok('/api/v1/assets/hdd/hdd_image2.qcow2')->status_is(404);
    $t->get_ok('/api/v1/assets/hdd/00099963-hdd_image2.qcow2')->status_is(404);
};

subtest 'last chunk is broken' => sub {
    my $pieces = OpenQA::File->new(file => Mojo::File->new($filename))->split($chunk_size);
    # Simulate an error - only the last chunk will be cksummed with an offending content
    # That will fail during total cksum calculation
    $pieces->each(
        sub {
            $_->content(int(rand(99999))) if $_->is_last;
            $_->prepare;
            my $chunk_asset = Mojo::Asset::Memory->new->add_chunk($_->serialize);
            $t->post_ok('/api/v1/jobs/99963/artefact' => form =>
                  {file => {file => $chunk_asset, filename => 'hdd_image.qcow2'}, asset => 'public'});
            $t->json_is('/error' => undef) unless $_->is_last();
            $t->json_like('/error', qr/Checksum mismatch expected/) if $_->is_last;
            ok(!-d $chunkdir, 'Chunk directory does not exist') if $_->is_last;
        });

    ok(!-d $chunkdir, 'Chunk directory does not exist - upload failed');
    $t->get_ok('/api/v1/assets/hdd/hdd_image2.qcow2')->status_is(404);
    $t->get_ok('/api/v1/assets/hdd/00099963-hdd_image2.qcow2')->status_is(404);
};

subtest 'Failed upload, public assets' => sub {
    my $pieces = OpenQA::File->new(file => Mojo::File->new($filename))->split($chunk_size);
    my $first_chunk = $pieces->first;
    $first_chunk->prepare;

    my $chunk_asset = Mojo::Asset::Memory->new->add_chunk($first_chunk->serialize);
    $t->post_ok('/api/v1/jobs/99963/artefact' => form =>
          {file => {file => $chunk_asset, filename => 'hdd_image.qcow2'}, asset => 'public'});
    $t->json_is('/status' => 'ok');
    ok(-d $chunkdir, 'Chunk directory exists');

    $t->post_ok('/api/v1/jobs/99963/upload_state' => form =>
          {filename => 'hdd_image.qcow2', scope => 'public', state => 'fail'});
    ok(!-d $chunkdir, 'Chunk directory was removed');
    ok((!-e path($chunkdir, $first_chunk->index)), 'Chunk was removed');
};

subtest 'Failed upload, private assets' => sub {
    $chunkdir = "$tempdir/openqa/share/factory/tmp/private/00099963/00099963-hdd_image.qcow2.CHUNKS";
    path($chunkdir)->dirname->remove_tree;

    my $pieces = OpenQA::File->new(file => Mojo::File->new($filename))->split($chunk_size);
    my $first_chunk = $pieces->first;
    $first_chunk->prepare;

    my $chunk_asset = Mojo::Asset::Memory->new->add_chunk($first_chunk->serialize);
    $t->post_ok('/api/v1/jobs/99963/artefact' => form =>
          {file => {file => $chunk_asset, filename => 'hdd_image.qcow2'}, asset => 'private'});
    $t->json_is('/status' => 'ok');
    ok(-d $chunkdir, 'Chunk directory exists');

    $t->post_ok(
        '/api/v1/jobs/99963/upload_state' => form => {
            filename => 'hdd_image.qcow2',
            scope => 'private',
            state => 'fail'
        });

    ok(!-d $chunkdir, 'Chunk directory was removed');
    ok((!-e path($chunkdir, $first_chunk->index)), 'Chunk was removed');

    $t->get_ok('/api/v1/assets/hdd/00099963-hdd_image.qcow2')->status_is(404);
};

sub _asset_names ($job) {
    [sort map { $_->asset->name } $job->jobs_assets->all]
}

subtest 'Chunks uploaded correctly, private asset registered and associated with jobs' => sub {
    # setup a child job which is expected to require the private asset
    my $parent_job = $jobs->find(99963);
    my $child_job = $jobs->create({TEST => 'child', settings => [{key => 'HDD_1', value => 'hdd_image.qcow2'}]});
    my %dependency = (child_job_id => $child_job->id, dependency => OpenQA::JobDependencies::Constants::CHAINED);
    $parent_job->children->create(\%dependency);
    $parent_job->jobs_assets->search({created_by => 1})->delete;    # cleanup assets from previous subtests

    my $pieces = OpenQA::File->new(file => Mojo::File->new($filename))->split($chunk_size);
    ok(!-d $chunkdir, 'Chunk directory empty');
    my $sum = OpenQA::File->file_digest($filename);
    is $sum, $pieces->first->total_cksum, 'Computed cksum matches';
    $pieces->each(
        sub {
            $_->prepare;
            my $chunk_asset = Mojo::Asset::Memory->new->add_chunk($_->serialize);
            $t->post_ok('/api/v1/jobs/99963/artefact' => form =>
                  {file => {file => $chunk_asset, filename => 'hdd_image.qcow2'}, asset => 'private'})->status_is(200);
            $t->json_is({status => 'ok'});
            ok(-d $chunkdir, 'Chunk directory exists') unless $_->is_last;
        });

    ok !-d $chunkdir, 'chunk directory should not exist anymore';
    ok -e "$tempdir/openqa/share/factory/hdd/00099963-hdd_image.qcow2", 'private asset exists after upload';

    # check whether private asset is registered and correctly associated with the parent and child job
    my @expected_assets = (qw(00099963-hdd_image.qcow2 openSUSE-13.1-DVD-x86_64-Build0091-Media.iso));
    $t->get_ok('/api/v1/assets/hdd/00099963-hdd_image.qcow2')->status_is(200)
      ->json_is('/name' => '00099963-hdd_image.qcow2', 'asset is registered');
    is_deeply _asset_names($parent_job), \@expected_assets, 'asset associated with job it has been created by';
    pop @expected_assets;    # child only requires hdd
    is_deeply _asset_names($child_job), \@expected_assets, 'asset associated with job supposed to use it';
};

subtest 'Tiny chunks, private assets' => sub {
    $chunkdir = "$tempdir/openqa/share/factory/tmp/00099963-new_ltp_result_array.json.CHUNKS/";
    path($chunkdir)->remove_tree;

    my $pieces = OpenQA::File->new(file => Mojo::File->new('t/data/new_ltp_result_array.json'))->split($chunk_size);
    is $pieces->size(), 1, 'Size should be 1';
    my $first_chunk = $pieces->first;
    $first_chunk->prepare;

    my $chunk_asset = Mojo::Asset::Memory->new->add_chunk($first_chunk->serialize);
    $t->post_ok('/api/v1/jobs/99963/artefact' => form =>
          {file => {file => $chunk_asset, filename => 'new_ltp_result_array.json'}, asset => 'other'});

    $t->json_is('/status' => 'ok');
    ok(!-d $chunkdir, 'Chunk directory does not exist');
    $t->get_ok('/api/v1/assets/other/00099963-new_ltp_result_array.json')->status_is(200);
};

my $query = Mojo::URL->new('/api/v1/jobs');

subtest 'filter by state and result' => sub {
    for my $state (OpenQA::Schema::Result::Jobs->STATES) {
        $query->query(state => $state);
        $t->get_ok($query->path_query)->status_is(200);
        my $res = $t->tx->res->json;
        for my $job (@{$res->{jobs}}) {
            is($job->{state}, $state, "Job state is $state");
        }
    }

    for my $result (OpenQA::Schema::Result::Jobs->RESULTS) {
        $query->query(result => $result);
        $t->get_ok($query->path_query)->status_is(200);
        my $res = $t->tx->res->json;
        for my $job (@{$res->{jobs}}) {
            is($job->{result}, $result, "Job result is $result");
        }
    }

    for my $result ('failed,none', 'passed,none', 'failed,passed') {
        $query->query(result => $result);
        $t->get_ok($query->path_query)->status_is(200);
        my $res = $t->tx->res->json;
        my $cond = $result =~ s/,/|/r;
        for my $job (@{$res->{jobs}}) {
            like($job->{result}, qr/$cond/, "Job result is $cond");
        }
    }

    $query->query(result => 'nonexistant_result');
    $t->get_ok($query->path_query)->status_is(200);
    my $res = $t->tx->res->json;
    ok(!@{$res->{jobs}}, 'no result for non-existant result');

    $query->query(state => 'nonexistant_state');
    $t->get_ok($query->path_query)->status_is(200);
    $res = $t->tx->res->json;
    ok(!@{$res->{jobs}}, 'no result for non-existant state');
};

subtest 'update job status' => sub {
    local $ENV{OPENQA_LOGFILE};
    local $ENV{OPENQA_WORKER_LOGDIR};
    OpenQA::App->singleton->log(Mojo::Log->new(handle => \*STDOUT));

    subtest 'update running job not providing any results/details' => sub {
        $t->post_ok('/api/v1/jobs/99963/status', json => {status => {worker_id => 1}})->status_is(200);
        my $response = $t->tx->res->json;
        my %expected_response = (job_result => 'failed', known_files => [], known_images => [], result => 1);
        is_deeply($response, \%expected_response, 'response as expected') or diag explain $response;
    };

    subtest 'update running job with results/details' => sub {
        # add a job module
        my $job = $jobs->find(99963);
        $job->modules->create({name => 'foo_module', category => 'selftests', script => 'foo_module.pm'});

        # ensure there are some known images/files
        my @known_images = qw(098f6bcd4621d373cade4e832627b4f6);
        my @known_files = qw(known-audio.wav known-text.txt);
        my $result_dir = $job->result_dir;
        note("result dir: $result_dir");
        for my $md5sum (@known_images) {
            my ($image_path, $thumbnail_path) = OpenQA::Utils::image_md5_filename($md5sum);
            my $file = path($image_path);
            $file->dirname->make_path;
            $file->spew('fake screenshot');
        }
        path($result_dir, $_)->spew('fake result') for @known_files;

        my @details = (
            {screenshot => {name => 'known-screenshot.png', md5 => '098f6bcd4621d373cade4e832627b4f6'}},
            {screenshot => {name => 'unknown-screenshot.png', md5 => 'ad0234829205b9033196ba818f7a872b'}},
            {text => 'known-text.txt'},
            {text => 'unknown-text.txt'},
            {audio => 'known-audio.wav'},
            {audio => 'unknown-audio.wav'},
        );
        my @post_args = (
            '/api/v1/jobs/99963/status',
            json => {
                status => {
                    worker_id => 1,
                    result => {
                        foo_module => {result => 'running', details => \@details},
                        bar_module => {result => 'none'},    # supposed to be ignored
                    },
                }});
        $t->post_ok(@post_args)->status_is(490, 'result upload returns error code if module does not exist');
        is $t->tx->res->json->{error}, 'Failed modules: bar_module', 'error specifies problematic module';

        $job->modules->create({name => 'bar_module', category => 'selftests', script => 'bar_module.pm'});
        $t->post_ok(@post_args)->status_is(200, 'result upload for existing module succeeds');
        my $response = $t->tx->res->json;
        my %expected_response
          = (job_result => 'failed', known_files => \@known_files, known_images => \@known_images, result => 1);
        is_deeply($response, \%expected_response, 'response as expected; only the known images and files returned')
          or diag explain $response;
        # note: The arrays are supposed to be sorted so it is fine to assume a fix order here.
    };

    subtest 'wrong parameters' => sub {
        combined_like {
            $t->post_ok('/api/v1/jobs/9999999/status', json => {})->status_is(400)
        }
        qr/Got status update for non-existing job/, 'status update for non-existing job rejected';
        combined_like {
            $t->post_ok('/api/v1/jobs/99764/status', json => {})->status_is(400)
        }
        qr/Got status update for job 99764 but does not contain a worker id!/,
          'status update without worker ID rejected';
        combined_like {
            $t->post_ok('/api/v1/jobs/99963/status', json => {status => {worker_id => 999999}})->status_is(400)
        }
        qr/Got status update for job 99963 with unexpected worker ID 999999 \(expected 1, job is running\)/,
          'status update for job that does not belong to worker rejected';
    };

    $schema->txn_begin;

    subtest 'update job which is already done' => sub {
        my $job = $jobs->find(99963);
        $job->worker->update({job_id => undef});
        $job->update({state => OpenQA::Jobs::Constants::DONE, result => OpenQA::Jobs::Constants::INCOMPLETE});
        combined_like {
            $t->post_ok('/api/v1/jobs/99963/status', json => {status => {worker_id => 999999}})->status_is(400)
        }
qr/Got status update for job 99963 with unexpected worker ID 999999 \(expected no updates anymore, job is done with result incomplete\)/,
          'status update for job that is already considered done rejected';
    };

    $schema->txn_rollback;
};

subtest 'get job status' => sub {
    $t->get_ok('/api/v1/experimental/jobs/80000/status')->status_is(200)->json_is('/id' => 80000, 'id present')
      ->json_is('/state' => 'done', 'status done')->json_is('/result' => 'passed', 'result passed')
      ->json_is('/blocked_by_id' => undef, 'blocked_by_id undef');
    $t->get_ok('/api/v1/experimental/jobs/999999999/status')->status_is(404)
      ->json_is('/error_status' => 404, 'Status code correct')->json_is('/error' => 'Job does not exist');
};

subtest 'cancel job' => sub {
    $t->post_ok('/api/v1/jobs/99963/cancel')->status_is(200);
    is_deeply(
        OpenQA::Test::Case::find_most_recent_event($schema, 'job_cancel'),
        {id => 99963, reason => undef},
        'Cancellation was logged correctly'
    );

    $t->post_ok('/api/v1/jobs/99963/cancel?reason=Undecided')->status_is(200);
    is_deeply(
        OpenQA::Test::Case::find_most_recent_event($schema, 'job_cancel'),
        {id => 99963, reason => 'Undecided'},
        'Cancellation was logged with reason'
    );

    my $form = {TEST => 'spam_eggs'};
    $t->post_ok('/api/v1/jobs', form => $form)->status_is(200);
    $t->post_ok('/api/v1/jobs/cancel', form => $form)->status_is(200);
    is($t->tx->res->json->{result}, 1, 'number of affected jobs returned') or diag explain $t->tx->res->json;
    is_deeply(OpenQA::Test::Case::find_most_recent_event($schema, 'job_cancel_by_settings'),
        $form, 'Cancellation was logged with settings');
};

# helper to find a build in the JSON results
sub find_build {
    my ($results, $build_id) = @_;

    for my $build_res (@{$results->{build_results}}) {
        log_debug('key: ' . $build_res->{key});
        if ($build_res->{key} eq $build_id) {
            return $build_res;
        }
    }
}

subtest 'json representation of group overview (actually not part of the API)' => sub {
    $t->get_ok('/group_overview/1001.json')->status_is(200)->json_is('/group/id' => 1001, 'group id present')->json_is(
        '/group/name' => 'opensuse',
        'group name present'
    );
    my $b48 = find_build($t->tx->res->json, 'Factory-0048');
    delete $b48->{oldest};
    is_deeply(
        $b48,
        {
            reviewed => 0,
            commented => 0,
            comments => 0,
            softfailed => 1,
            failed => 1,
            labeled => 0,
            all_passed => 0,
            total => 3,
            passed => 0,
            skipped => 0,
            distris => {'opensuse' => 1},
            unfinished => 1,
            version => 'Factory',
            version_count => 1,
            escaped_version => 'Factory',
            build => '0048',
            escaped_build => '0048',
            escaped_id => 'Factory-0048',
            key => 'Factory-0048',
        },
        'Build 0048 exported'
    ) or diag explain $b48;
};

$t->get_ok('/dashboard_build_results.json?limit_builds=10')->status_is(200);
my $ret = $t->tx->res->json;
is(@{$ret->{results}}, 2);
my $g1 = (shift @{$ret->{results}});
is($g1->{group}->{name}, 'opensuse', 'First group is opensuse');
my $b1 = find_build($g1, '13.1-0092');
delete $b1->{oldest};
is_deeply(
    $b1,
    {
        passed => 1,
        version => '13.1',
        distris => {'opensuse' => 1},
        labeled => 0,
        total => 1,
        failed => 0,
        unfinished => 0,
        skipped => 0,
        reviewed => '1',
        commented => '1',
        comments => 0,
        softfailed => 0,
        all_passed => 1,
        version => '13.1',
        version_count => 1,
        escaped_version => '13_1',
        build => '0092',
        escaped_build => '0092',
        escaped_id => '13_1-0092',
        key => '13.1-0092',
    },
    'Build 92 of opensuse'
);

my %jobs_post_params = (
    iso => 'openSUSE-%VERSION%-%FLAVOR%-x86_64-Current.iso',
    DISTRI => 'opensuse',
    VERSION => 'Tumbleweed',
    FLAVOR => 'DVD',
    TEST => 'awesome',
    MACHINE => '64bit',
    BUILD => '1234',
    _GROUP => 'opensuse',
);

subtest 'WORKER_CLASS correctly assigned when posting job' => sub {
    my $id;
    $t->post_ok('/api/v1/jobs', form => \%jobs_post_params)->status_is(200);
    ok $id = $t->tx->res->json->{id}, 'id returned (0)' or diag explain $t->tx->res->json;
    is $jobs->find($id)->settings_hash->{WORKER_CLASS}, 'qemu_x86_64',
      'default WORKER_CLASS assigned (with arch fallback)';

    $jobs_post_params{ARCH} = 'aarch64';
    $t->post_ok('/api/v1/jobs', form => \%jobs_post_params)->status_is(200);
    ok $id = $t->tx->res->json->{id}, 'id returned (1)' or diag explain $t->tx->res->json;
    is $jobs->find($id)->settings_hash->{WORKER_CLASS}, 'qemu_aarch64', 'default WORKER_CLASS assigned';

    $jobs_post_params{WORKER_CLASS} = 'svirt';
    $t->post_ok('/api/v1/jobs', form => \%jobs_post_params)->status_is(200);
    ok $id = $t->tx->res->json->{id}, 'id returned (2)' or diag explain $t->tx->res->json;
    is $jobs->find($id)->settings_hash->{WORKER_CLASS}, 'svirt', 'specified WORKER_CLASS assigned';
};

subtest 'default priority correctly assigned when posting job' => sub {
    # post new job and check default priority
    $t->post_ok('/api/v1/jobs', form => \%jobs_post_params)->status_is(200);
    $t->get_ok('/api/v1/jobs/' . $t->tx->res->json->{id})->status_is(200);
    $t->json_is('/job/group', 'opensuse');
    $t->json_is('/job/priority', 50);

    # post new job in job group with customized default priority
    $schema->resultset('JobGroups')->find({name => 'opensuse test'})->update({default_priority => 42});
    $jobs_post_params{_GROUP} = 'opensuse test';
    $t->post_ok('/api/v1/jobs', form => \%jobs_post_params)->status_is(200);
    $t->get_ok('/api/v1/jobs/' . $t->tx->res->json->{id})->status_is(200);
    $t->json_is('/job/group', 'opensuse test');
    $t->json_is('/job/priority', 42);
};

subtest 'specifying group by ID' => sub {
    delete $jobs_post_params{_GROUP};
    $jobs_post_params{_GROUP_ID} = 1002;
    $t->post_ok('/api/v1/jobs', form => \%jobs_post_params)->status_is(200);
    $t->get_ok('/api/v1/jobs/' . $t->tx->res->json->{id})->status_is(200);
    $t->json_is('/job/group', 'opensuse test');
    $t->json_is('/job/priority', 42);
};

subtest 'TEST is only mandatory parameter' => sub {
    $t->post_ok('/api/v1/jobs', form => {TEST => 'pretty_empty'})->status_is(200);
    $t->get_ok('/api/v1/jobs/' . $t->tx->res->json->{id})->status_is(200);
    $t->json_is('/job/settings/TEST' => 'pretty_empty');
    $t->json_is('/job/settings/MACHINE' => undef, 'machine was not set and is therefore undef');
    $t->json_is('/job/settings/DISTRI' => undef);
};

subtest 'Job with JOB_TEMPLATE_NAME' => sub {
    $jobs_post_params{JOB_TEMPLATE_NAME} = 'foo';
    $t->post_ok('/api/v1/jobs', form => \%jobs_post_params)->status_is(200, 'posted job with job template name');
    like(
        $jobs->find($t->tx->res->json->{id})->settings_hash->{NAME},
        qr/\d+-opensuse-Tumbleweed-DVD-aarch64-Build1234-foo@64bit/,
        'job template name reflected in scenario name'
    );
    delete $jobs_post_params{JOB_TEMPLATE_NAME};
};

subtest 'posting multiple jobs at once' => sub {
    my %jobs_post_params = (
        'TEST:0' => 'root-job',
        'TEST:1' => 'follow-up-job-1',
        '_START_AFTER:1' => '0',
        'TEST:2' => 'follow-up-job-2',
        '_START_AFTER:2' => '0',
        'TEST:3' => 'parallel-job',
        '_PARALLEL:3' => '1,2'
    );
    $t->post_ok('/api/v1/jobs', form => \%jobs_post_params)->status_is(200, 'posted multiple jobs');
    my $json = $t->tx->res->json;
    diag explain $json or return unless $t->success;
    my $ids = $json->{ids};
    is ref $ids, 'HASH', 'mapping of suffixes to IDs returned' or diag explain $json;
    ok my $root_job_id = $ids->{0}, 'root-job created';
    ok my $follow_up_job_1_id = $ids->{1}, 'follow-up-job-1 created';
    ok my $follow_up_job_2_id = $ids->{2}, 'follow-up-job-2 created';
    ok my $parallel_job_id = $ids->{3}, 'parallel-job created';
    ok my $root_job = $jobs->find($root_job_id), 'root job actually exists';
    ok my $follow_up_job_1 = $jobs->find($follow_up_job_1_id), 'follow-up job 1 job actually exists';
    ok my $follow_up_job_2 = $jobs->find($follow_up_job_2_id), 'follow-up job 2 job actually exists';
    my @d = map { $_ => [] }
      qw(chained_children chained_parents directly_chained_children directly_chained_parents parallel_children parallel_parents);
    push @d, ok => 0, state => SCHEDULED;
    is $root_job->TEST, 'root-job', "name of root job ($root_job_id) correct";
    is $follow_up_job_1->TEST, 'follow-up-job-1', "name of follow-up 1 ($follow_up_job_1_id) correct";
    is $follow_up_job_2->TEST, 'follow-up-job-2', "name of follow-up 2 ($follow_up_job_2_id) correct";
    is $jobs->find($parallel_job_id)->TEST, 'parallel-job', "name of parallel job ($parallel_job_id) correct";
    my %expected_cluster = (
        $parallel_job_id => {@d, parallel_parents => [sort $follow_up_job_1_id, $follow_up_job_2_id]},
        $follow_up_job_1_id => {@d, chained_parents => [$root_job_id], parallel_children => [$parallel_job_id]},
        $follow_up_job_2_id => {@d, chained_parents => [$root_job_id], parallel_children => [$parallel_job_id]},
        $root_job_id => {@d, chained_children => [sort $follow_up_job_1_id, $follow_up_job_2_id]});
    my $created_cluster = $root_job->cluster_jobs;
    for my $job_id (keys %$created_cluster) {
        # ensure the dependencies are always sorted in the same way
        my $deps = $created_cluster->{$job_id};
        delete $deps->{is_parent_or_initial_job};
        $deps->{parallel_parents} = [sort @{$deps->{parallel_parents}}];
        $deps->{chained_children} = [sort @{$deps->{chained_children}}];
    }
    is_deeply $created_cluster, \%expected_cluster, 'expected cluster created' or diag explain $created_cluster;
    is $follow_up_job_1->blocked_by_id, $root_job_id, 'blocked by computed (0)';
    is $follow_up_job_2->blocked_by_id, $root_job_id, 'blocked by computed (1)';
};

subtest 'handle settings when posting job' => sub {
    my $machines = $schema->resultset('Machines');
    $machines->create(
        {
            name => '64bit',
            backend => 'qemu',
            settings => [{key => "QEMUCPU", value => "qemu64"},],
        });
    $products->create(
        {
            version => '15-SP1',
            name => '',
            distri => 'sle',
            arch => 'x86_64',
            description => '',
            flavor => 'Installer-DVD',
            settings => [
                {key => 'BUILD_SDK', value => '%BUILD%'},
                {key => '+ISO_MAXSIZE', value => '4700372992'},
                {
                    key => '+HDD_1',
                    value => 'SLES-%VERSION%-%ARCH%-%BUILD%@%MACHINE%-minimal_with_sdk%BUILD_SDK%_installed.qcow2'
                },
            ],
        });
    $testsuites->create(
        {
            name => 'autoupgrade',
            description => '',
            settings => [{key => 'ISO_MAXSIZE', value => '50000000'},],
        });

    my %new_jobs_post_params = (
        HDD_1 => 'foo.qcow2',
        DISTRI => 'sle',
        VERSION => '15-SP1',
        FLAVOR => 'Installer-DVD',
        ARCH => 'x86_64',
        TEST => 'autoupgrade',
        MACHINE => '64bit',
        BUILD => '1234',
        ISO_MAXSIZE => '60000000',
    );

    subtest 'handle settings from Machine, Testsuite, Product variables' => sub {
        $t->post_ok('/api/v1/jobs', form => \%new_jobs_post_params)->status_is(200);
        my $result = $jobs->find($t->tx->res->json->{id})->settings_hash;
        delete $result->{NAME};
        is_deeply(
            $result,
            {
                %new_jobs_post_params,
                HDD_1 => 'SLES-15-SP1-x86_64-1234@64bit-minimal_with_sdk1234_installed.qcow2',
                ISO_MAXSIZE => '4700372992',
                BUILD_SDK => '1234',
                QEMUCPU => 'qemu64',
                BACKEND => 'qemu',
                WORKER_CLASS => 'qemu_x86_64'
            },
            'expand specified Machine, TestSuite, Product variables and handle + in settings correctly'
        );
    };

    subtest 'circular reference settings' => sub {
        $new_jobs_post_params{BUILD} = '%BUILD_SDK%';
        $t->post_ok('/api/v1/jobs', form => \%new_jobs_post_params)->status_is(400);
        like(
            $t->tx->res->json->{error},
            qr/The key (\w+) contains a circular reference, its value is %\w+%/,
            'circular reference exit successfully'
        );
    };
};

subtest 'do not re-generate settings when cloning job' => sub {
    my %attrs = (rows => 1, order_by => {-desc => 'id'});
    my $job_settings = $jobs->find({test => 'autoupgrade'}, \%attrs)->settings_hash;
    clone_job_apply_settings([qw(BUILD_SDK= ISO_MAXSIZE=)], 0, $job_settings, {});
    $job_settings->{is_clone_job} = 1;
    $t->post_ok('/api/v1/jobs', form => $job_settings)->status_is(200);
    my $new_job_settings = $jobs->find($t->tx->res->json->{id})->settings_hash;
    delete $job_settings->{is_clone_job};
    delete $new_job_settings->{NAME};
    is_deeply($new_job_settings, $job_settings, 'did not re-generate settings');
};

# use regular test results for fixtures in subsequent tests
$ENV{OPENQA_BASEDIR} = 't/data';

subtest 'error on insufficient params' => sub {
    $t->post_ok('/api/v1/jobs', form => {})->status_is(400);
};

subtest 'job details' => sub {
    $t->get_ok('/api/v1/jobs/99926')->status_is(200);
    $t->json_is('/job/testresults' => undef, 'Test details are not present');
    $t->json_hasnt('/job/logs/0' => undef, 'Test result logs are empty');

    $t->get_ok('/api/v1/jobs/99963/details')->status_is(200);
    $t->json_has('/job/testresults/0', 'Test details are there');
    $t->json_is('/job/assets/hdd/0', => '00099963-hdd_image.qcow2', 'Job has private hdd_image.qcow2 as asset');
    $t->json_is('/job/testresults/0/category', => 'installation', 'Job category is "installation"');

    $t->get_ok('/api/v1/jobs/99946/details')->status_is(200);
    $t->json_has('/job/testresults/0', 'Test details are there');
    $t->json_is('/job/assets/hdd/0', => 'openSUSE-13.1-x86_64.hda', 'Job has openSUSE-13.1-x86_64.hda as asset');
    $t->json_is('/job/testresults/0/category', => 'installation', 'Job category is "installation"');

    $t->json_is('/job/testresults/5/name', 'logpackages', 'logpackages test is present');
    $t->json_like('/job/testresults/5/details/8/text_data', qr/fate/, 'logpackages has fate');

    $t->get_ok('/api/v1/jobs/99938/details')->status_is(200);

    $t->json_is('/job/logs/0', 'video.ogv', 'Test result logs are present');
    $t->json_is('/job/ulogs/0', 'y2logs.tar.bz2', 'Test result uploaded logs are present');

};

subtest 'check for missing assets' => sub {
    $t->get_ok('/api/v1/jobs/99939?check_assets=1')->status_is(200, 'status for job with missing asset');
    $t->json_is('/job/assets/hdd/0', 'openSUSE-13.1-x86_64.hda', 'present asset returned');
    $t->json_is(
        '/job/missing_assets/0',
        'iso/openSUSE-Factory-DVD-x86_64-Build0048-Media.iso',
        'missing asset returned'
    );

    $t->get_ok('/api/v1/jobs/99927?check_assets=1')->status_is(200, 'status for job without missing assets');
    $t->json_is('/job/missing_assets/0', undef, 'no missing asset returned for 99927');
};

subtest 'update job and job settings' => sub {
    # check defaults
    $t->get_ok('/api/v1/jobs/99926')->status_is(200);
    $t->json_is('/job/group' => 'opensuse', 'current group');
    $t->json_is('/job/priority' => 56, 'current prio');
    $t->json_is('/job/settings/ARCH' => 'x86_64', 'current ARCH');
    $t->json_is('/job/settings/FLAVOR' => 'staging_e', 'current FLAVOR');

    # error cases
    $t->put_ok('/api/v1/jobs/3134', json => {group_id => 1002})->status_is(404);
    $t->json_is('/error' => 'Job does not exist', 'error when job id is invalid');
    $t->put_ok('/api/v1/jobs/99926', json => {group_id => 1234})->status_is(404);
    $t->json_is('/error' => 'Group does not exist', 'error when group id is invalid');
    $t->put_ok('/api/v1/jobs/99926', json => {group_id => 1002, status => 1})->status_is(400);
    $t->json_is('/error' => 'Column status can not be set', 'error when invalid/not accessible column specified');

    # set columns of job table
    $t->put_ok('/api/v1/jobs/99926', json => {group_id => 1002, priority => 53})->status_is(200);
    $t->get_ok('/api/v1/jobs/99926')->status_is(200);
    $t->json_is('/job/group' => 'opensuse test', 'group changed');
    $t->json_is('/job/priority' => 53, 'priority change');
    $t->json_is('/job/settings/ARCH' => 'x86_64', 'settings in job table not altered');
    $t->json_is('/job/settings/DESKTOP' => 'minimalx', 'settings in job settings table not altered');

    $t->put_ok(
        '/api/v1/jobs/99926',
        json => {
            priority => 50,
            settings => {
                TEST => 'minimalx',
                ARCH => 'i686',
                DESKTOP => 'kde',
                NEW_KEY => 'new value',
                WORKER_CLASS => ':MiB:Promised_Land',
            },
        })->status_is(200, 'job settings set');
    $t->get_ok('/api/v1/jobs/99926')->status_is(200);
    $t->json_is('/job/group' => 'opensuse test', 'group remained the same');
    $t->json_is('/job/priority' => 50, 'priority change');
    $t->json_is('/job/settings/ARCH' => 'i686', 'ARCH changed');
    $t->json_is('/job/settings/DESKTOP' => 'kde', 'DESKTOP changed');
    $t->json_is('/job/settings/NEW_KEY' => 'new value', 'NEW_KEY created');
    $t->json_is('/job/settings/FLAVOR' => undef, 'FLAVOR removed');

    $t->put_ok('/api/v1/jobs/99926', json => {group_id => undef})->status_is(200);
    $t->get_ok('/api/v1/jobs/99926')->status_is(200);
    $t->json_is('/job/group' => undef, 'group removed');

    $t->put_ok(
        '/api/v1/jobs/99926',
        json => {
            settings => {
                MACHINE => '64bit',
                WORKER_CLASS => ':UFP:NCC1701F',
            }})->status_is(200, 'machine set');
    $t->get_ok('/api/v1/jobs/99926')->status_is(200);
    $t->json_is(
        '/job/settings' => {
            NAME => '00099926-@64bit',
            MACHINE => '64bit',
            WORKER_CLASS => ':UFP:NCC1701F',
        },
        'also name and worker class updated, all other settings cleaned'
    );
};

subtest 'filter by worker_class' => sub {
    $query->query(worker_class => ':MiB:');
    $t->get_ok($query->path_query)->status_is(200);
    my $res = $t->tx->res->json;
    ok(!@{$res->{jobs}}, 'Worker class does not exist');

    $query->query(worker_class => '::');
    $t->get_ok($query->path_query)->status_is(200);
    $res = $t->tx->res->json;
    ok(!@{$res->{jobs}}, 'Wrong worker class provides zero results');

    $query->query(worker_class => ':UFP:');
    $t->get_ok($query->path_query)->status_is(200);
    $res = $t->tx->res->json;
    ok(@{$res->{jobs}} eq 1, 'Known worker class group exists, and returns one job');

    $t->json_is('/jobs/0/settings/WORKER_CLASS' => ':UFP:NCC1701F', 'Correct worker class');
};

sub junit_ok {
    my ($parser, $jobid, $basedir, $result_files) = @_;

    ok -e path($basedir, $_), "$_ written" for @$result_files;

    for my $result (@{$parser->results}) {
        my $testname = $result->test->name;
        subtest "Parsed results for $testname" => sub {
            my $db_module = $jobs->find($jobid)->modules->find({name => $testname});
            my $jobresult = 'passed';
            if ($result->result eq 'skip' or $result->result eq 'conf') {
                $jobresult = 'skipped';
            }
            elsif ($result->result eq 'fail' or $result->result eq 'brok') {
                $jobresult = 'failed';
            }
            ok(-e path($basedir, "details-$testname.json"), 'junit details written');
            my $got_details = {
                results => {
                    details => $db_module->results->{details},
                },
                name => $db_module->name,
                script => $db_module->script,
                category => $db_module->category,
                result => $db_module->result,
            };
            my $expected_details = {
                results => {
                    details => $result->details,
                },
                name => $testname,
                script => 'test',
                category => $result->test->category,
                result => $jobresult,
            };
            for my $step (@{$got_details->{results}->{details}}) {
                next unless $step->{text};
                ok(delete $step->{text_data}, 'text data loaded');
            }
            is_deeply($got_details, $expected_details, 'Module details match');
            ok(-e path($basedir, $_->{text}), 'Path exists') for @{$db_module->results->{details}};
        };
    }

    for my $output (@{$parser->outputs}) {
        is path($basedir, $output->file)->slurp, $output->content, $output->file . ' written';
    }
}

subtest 'Parse extra tests results - LTP' => sub {
    my $fname = 'new_ltp_result_array.json';
    my $junit = "t/data/$fname";
    my $parser = parser('LTP');
    $parser->include_results(1);
    $parser->load($junit);
    my $jobid = 99963;
    my $basedir = "t/data/openqa/testresults/00099/00099963-opensuse-13.1-DVD-x86_64-Build0091-kde/";

    stdout_like(
        sub {
            $t->post_ok(
                '/api/v1/jobs/99963/artefact' => form => {
                    file => {file => $junit, filename => $fname},
                    type => 'JUnit',
                    extra_test => 1,
                    script => 'test'
                })->status_is(400, 'request considered invalid (JUnit)');
        },
        qr/Failed parsing data JUnit for job 99963: Failed parsing XML at/,
        'XML parsing error logged'
    );
    $t->json_is('/error' => 'Unable to parse extra test', 'error returned (JUnit)')
      or diag explain $t->tx->res->content;

    $t->post_ok(
        "/api/v1/jobs/$jobid/artefact" => form => {
            file => {file => $junit, filename => $fname},
            type => 'foo',
            extra_test => 1,
            script => 'test'
        })->status_is(400, 'request considered invalid (foo)');
    $t->json_is('/error' => 'Unable to parse extra test', 'error returned (foo)') or diag explain $t->tx->res->content;
    ok !-e path($basedir, 'details-LTP_syscalls_accept01.json'), 'detail from LTP was NOT written';

    $t->post_ok(
        "/api/v1/jobs/$jobid/artefact" => form => {
            file => {file => $junit, filename => $fname},
            type => 'LTP',
            extra_test => 1,
            script => 'test'
        })->status_is(200, 'request went fine');
    $t->content_is('OK', 'ok returned');
    ok !-e path($basedir, $fname), 'file was not uploaded';

    is $parser->tests->size, 7, 'Tests parsed correctly' or diag explain $parser->tests->size;
    junit_ok $parser, $jobid, $basedir, ['details-LTP_syscalls_accept01.json', 'LTP-LTP_syscalls_accept01.txt'];
};

subtest 'Parse extra tests results - xunit' => sub {
    my $fname = 'xunit_format_example.xml';
    my $junit = "t/data/$fname";
    my $parser = parser('XUnit');
    $parser->include_results(1);
    $parser->load($junit);
    my $jobid = 99963;
    my $basedir = "t/data/openqa/testresults/00099/00099963-opensuse-13.1-DVD-x86_64-Build0091-kde/";

    $t->post_ok(
        "/api/v1/jobs/$jobid/artefact" => form => {
            file => {file => $junit, filename => $fname},
            type => 'LTP',
            extra_test => 1,
            script => 'test'
        })->status_is(400, 'request considered invalid (LTP)');
    $t->json_is('/error' => 'Unable to parse extra test', 'error returned (LTP)') or diag explain $t->tx->res->content;

    $t->post_ok(
        "/api/v1/jobs/$jobid/artefact" => form => {
            file => {file => $junit, filename => $fname},
            type => 'foo',
            extra_test => 1,
            script => 'test'
        })->status_is(400, 'request considered invalid (foo)');
    $t->json_is('/error' => 'Unable to parse extra test', 'error returned (foo)') or diag explain $t->tx->res->content;
    ok !-e path($basedir, 'details-unkn.json'), 'detail from junit was NOT written';

    $t->post_ok(
        "/api/v1/jobs/$jobid/artefact" => form => {
            file => {file => $junit, filename => $fname},
            type => 'XUnit',
            extra_test => 1,
            script => 'test'
        })->status_is(200, 'request went fine');
    $t->content_is('OK', 'ok returned');
    ok !-e path($basedir, $fname), 'file was not uploaded';

    is $parser->tests->size, 11, 'Tests parsed correctly' or diag explain $parser->tests->size;
    junit_ok $parser, $jobid, $basedir, ['details-unkn.json', 'xunit-bacon-1.txt'];
};

subtest 'Parse extra tests results - junit' => sub {
    my $fname = 'junit-results.xml';
    my $junit = "t/data/$fname";
    my $parser = parser('JUnit');
    $parser->include_results(1);
    $parser->load($junit);
    my $jobid = 99963;
    my $basedir = "t/data/openqa/testresults/00099/00099963-opensuse-13.1-DVD-x86_64-Build0091-kde/";

    $t->post_ok(
        "/api/v1/jobs/$jobid/artefact" => form => {
            file => {file => $junit, filename => $fname},
            type => 'foo',
            extra_test => 1,
            script => 'test'
        })->status_is(400, 'request considered invalid (foo)');
    $t->json_is('/error' => 'Unable to parse extra test', 'error returned (foo)') or diag explain $t->tx->res->content;
    ok !-e path($basedir, 'details-1_running_upstream_tests.json'), 'detail from junit was NOT written';

    $t->post_ok(
        "/api/v1/jobs/$jobid/artefact" => form => {
            file => {file => $junit, filename => $fname},
            type => "JUnit",
            extra_test => 1,
            script => 'test'
        })->status_is(200, 'request went fine');
    $t->content_is('OK', 'ok returned');
    ok !-e path($basedir, $fname), 'file was not uploaded';

    ok $parser->tests->size > 2, 'Tests parsed correctly';
    junit_ok $parser, $jobid, $basedir,
      ['details-1_running_upstream_tests.json', 'tests-systemd-9_post-tests_audits-3.txt'];
};

subtest 'create job failed when PUBLISH_HDD_1 is invalid' => sub {
    $jobs_post_params{PUBLISH_HDD_1} = 'foo/foo@64bit.qcow2';
    $t->post_ok('/api/v1/jobs', form => \%jobs_post_params)->status_is(400);
    $t->json_like('/error', qr/The PUBLISH_HDD_1 cannot include \/ in value/, 'PUBLISH_HDD_1 is invalid');
};

subtest 'show job modules execution time' => sub {
    my %modules_execution_time = (
        aplay => '2m 26s',
        consoletest_finish => '2m 44s',
        gnucash => '3m 7s',
        installer_timezone => '34s'
    );
    $t->get_ok('/api/v1/jobs/99937/details');
    my @testresults = sort { $a->{name} cmp $b->{name} } @{$t->tx->res->json->{job}->{testresults}};
    my %execution_times = map { $_->{name} => $_->{execution_time} } @testresults;
    for my $module_name (keys %modules_execution_time) {
        is(
            $execution_times{$module_name},
            $modules_execution_time{$module_name},
            $module_name . ' execution time showed correctly'
        );
    }
    is(scalar(@{$testresults[0]->{details}}), 2, 'the old format json file parsed correctly');
    is($testresults[0]->{execution_time}, undef, 'the old format json file does not include execution_time');
};

subtest 'marking job as done' => sub {
    subtest 'obsolete job via newbuild parameter' => sub {
        $jobs->find(99961)->update({state => RUNNING, result => NONE, reason => undef});
        $t->post_ok('/api/v1/jobs/99961/set_done?newbuild=1')->status_is(200);
        $t->json_is('/result' => OBSOLETED, 'post yields incomplete result');
        $t->get_ok('/api/v1/jobs/99961')->status_is(200);
        $t->json_is('/job/result' => OBSOLETED, 'get yields result');
        is_deeply(
            OpenQA::Test::Case::find_most_recent_event($schema, 'job_done'),
            {id => 99961, result => OBSOLETED, reason => undef, newbuild => 1},
            'Create was logged correctly'
        );
    };

    my $cache_failure_reason = 'cache failure: No active workers';
    my %cache_failure_params = (result => INCOMPLETE, reason => $cache_failure_reason);
    subtest 'job is currently running' => sub {
        $jobs->find(99961)->update({state => RUNNING, result => NONE, reason => undef});
        $t->post_ok('/api/v1/jobs/99961/set_done?result=incomplet')->status_is(400, 'invalid result rejected');
        $t->json_like('/error', qr/result invalid/, 'error message returned');
        $t->post_ok('/api/v1/jobs/99961/set_done?result=incomplete&reason=test&worker_id=1');
        $t->status_is(400, 'set_done with worker_id rejected if job no longer assigned');
        $t->json_like('/error', qr/Refusing.*because.*re-scheduled/, 'error message returned');

        $schema->txn_begin;
        $jobs->find(99961)->update({assigned_worker_id => 1});
        $t->post_ok('/api/v1/jobs/99961/set_done?result=incomplete&reason=test&worker_id=42');
        $t->status_is(400, 'set_done with worker_id rejected if job assigned to different worker');
        $t->json_like('/error', qr/Refusing.*because.*assigned to worker 1/, 'error message returned');
        $t->post_ok('/api/v1/jobs/99961/set_done?result=failed&reason=test&worker_id=1');
        $t->status_is(200, 'set_done accepted with correct worker_id');
        $t->json_is('/result' => FAILED, 'post yields failed result (explicitely specified)');
        perform_minion_jobs($t->app->minion);
        my $job = $jobs->find(99961);
        is $job->clone_id, undef, 'job not cloned when reason does not match configured regex';
        is $job->result, FAILED, 'result is failure (as passed via param)';
        $schema->txn_rollback;

        $schema->txn_begin;
        $t->post_ok('/api/v1/jobs/99961/set_done')->status_is(200);
        $t->json_is('/result' => INCOMPLETE, 'post yields incomplete result (calculated)');
        $t->success or diag explain $t->tx->res->json;
        $job = $jobs->find(99961);
        is $job->result, INCOMPLETE, 'result is incomplete (no modules and no reason explicitely specified)';
        is $job->reason, 'no test modules scheduled/uploaded', 'reason for incomplete set';
        $schema->txn_rollback;

        $t->post_ok(Mojo::URL->new('/api/v1/jobs/99961/set_done')->query(\%cache_failure_params));
        $t->status_is(200, 'set_done accepted without worker_id');
        perform_minion_jobs($t->app->minion);
        $t->get_ok('/api/v1/jobs/99961')->status_is(200);
        $t->json_is('/job/result' => INCOMPLETE, 'result set');
        $t->json_like('/job/reason' => qr{\Q$cache_failure_reason}, 'reason set');
        $t->json_is('/job/state' => DONE, 'state set');
        $t->json_like('/job/clone_id' => qr/\d+/, 'job cloned when reason does match configured regex');

    };
    subtest 'job is already done with reason, not overriding existing result and reason' => sub {
        $t->post_ok('/api/v1/jobs/99961/set_done?result=passed&reason=foo')->status_is(200);
        $t->json_is('/result' => INCOMPLETE, 'post yields result (old result as not overridden)');
        $t->get_ok('/api/v1/jobs/99961')->status_is(200);
        $t->json_is('/job/result' => INCOMPLETE, 'result unchanged');
        $t->json_like('/job/reason' => qr{\Q$cache_failure_reason}, 'reason unchanged');
    };
    my $reason_cutted = join('', map { 'ä' } (1 .. 300));
    my $reason = $reason_cutted . ' additional characters';
    $reason_cutted .= '…';
    subtest 'job is already done without reason, add reason but do not override result' => sub {
        $jobs->find(99961)->update({reason => undef});
        $t->post_ok("/api/v1/jobs/99961/set_done?result=passed&reason=$reason")->status_is(200);
        $t->get_ok('/api/v1/jobs/99961')->status_is(200);
        $t->json_is('/job/reason' => $reason_cutted, 'reason updated, cutted to 120 characters');
    };
    subtest 'job is already done, no parameters specified' => sub {
        $t->post_ok('/api/v1/jobs/99961/set_done')->status_is(200);
        $t->json_is('/result' => INCOMPLETE, 'post yields incomplete result (already existing result)');
        $t->get_ok('/api/v1/jobs/99961')->status_is(200);
        $t->json_is('/job/result' => INCOMPLETE, 'previous result not lost');
        $t->json_is('/job/reason' => $reason_cutted, 'previous reason not lost');
    };
    subtest 'restart job when incomplete in failed to allocate KVM' => sub {
        my $incomplete_reason
          = 'QEMU terminated: Failed to allocate KVM HPT of order 25 (try smaller maxmem?): Cannot allocate memory, see log output of details';
        $jobs->find(99961)->update({reason => undef});
        $jobs->find(99961)->update({clone_id => undef});
        $t->get_ok('/api/v1/jobs/99961')->status_is(200);
        $t->post_ok(
            Mojo::URL->new('/api/v1/jobs/99961/set_done')->query({result => INCOMPLETE, reason => $incomplete_reason}));
        perform_minion_jobs($t->app->minion);
        $t->get_ok('/api/v1/jobs/99961')->status_is(200);
        $t->json_is('/job/result' => INCOMPLETE, 'the job status is correct');
        $t->json_like('/job/reason' => qr{\Q$incomplete_reason}, 'the incomplete reason is correct');
        $t->json_like('/job/clone_id' => qr/\d+/, 'job was cloned when reason matches the configured regex');
    };
};

subtest 'handle FOO_URL' => sub {
    $testsuites->create(
        {
            name => 'handle_foo_url',
            description => '',
            settings => [
                {key => 'ISO_1_URL', value => 'http://localhost/foo.iso'},
                {key => 'HDD_1', value => 'hdd@%MACHINE%.qcow2'}
            ],
        });
    my $params = {
        TEST => 'handle_foo_url',
        HDD_1_URL => 'http://localhost/hdd.qcow2',
        MACHINE => '64bit',
    };
    $t->post_ok('/api/v1/jobs', form => $params)->status_is(200);

    my $job_id = $t->tx->res->json->{id};
    my $result = $jobs->find($job_id)->settings_hash;
    is($result->{ISO_1}, 'foo.iso', 'the ISO_1 was added in job setting');
    is($result->{HDD_1}, 'hdd@64bit.qcow2', 'the HDD_1 was overwritten by the value in testsuite settings');

    my %gru_task_values;
    foreach my $gru_dep ($schema->resultset('GruDependencies')->search({job_id => $job_id})) {
        my $gru_task = $gru_dep->gru_task;
        is $gru_task->taskname, 'download_asset', 'the download asset was created';
        my @gru_args = @{$gru_task->args};
        $gru_task_values{shift @gru_args} = \@gru_args;
    }
    is_deeply \%gru_task_values,
      {
        'http://localhost/hdd.qcow2' => [locate_asset('hdd', 'hdd@64bit.qcow2', mustexist => 0), 0],
        'http://localhost/foo.iso' => [locate_asset('iso', 'foo.iso', mustexist => 0), 0],
      },
      'the download gru tasks were created correctly';
};

subtest 'handle git CASEDIR' => sub {
    $testsuites->create(
        {
            name => 'handle_foo_casedir',
            description => '',
            settings => [
                {key => 'CASEDIR', value => 'http://localhost/foo.git'},
                {key => 'DISTRI', value => 'foobar'},
                {key => 'NEEDLES_DIR', value => 'http://localhost/bar.git'}
            ],
        });
    my $params = {TEST => 'handle_foo_casedir',};
    OpenQA::App->singleton->config->{'scm git'}->{git_auto_clone} = 'yes';
    $t->post_ok('/api/v1/jobs', form => $params)->status_is(200);

    my $job_id = $t->tx->res->json->{id};
    my $result = $jobs->find($job_id)->settings_hash;

    my $gru_dep = $schema->resultset('GruDependencies')->find({job_id => $job_id});
    my $gru_task = $gru_dep->gru_task;
    is $gru_task->taskname, 'git_clone', 'the git clone job was created';
    my @gru_args = @{$gru_task->args};
    my $gru_task_values = shift @gru_args;
    is_deeply $gru_task_values,
      {
        't/data/openqa/share/tests/foobar' => 'http://localhost/foo.git',
        't/data/openqa/share/tests/foobar/needles' => 'http://localhost/bar.git'
      },
      'the git clone gru tasks were created correctly';
};

subtest 'show parent group name and id when getting job details' => sub {
    my $parent_group = $schema->resultset('JobGroupParents')->create({name => 'Foo'});
    my $parent_group_id = $parent_group->id;
    my $job_group_id = $jobs->find(99963)->group_id;
    $schema->resultset('JobGroups')->find($job_group_id)->update({parent_id => $parent_group_id});
    $t->get_ok('/api/v1/jobs/99963')->status_is(200);
    my $job = $t->tx->res->json->{job};
    is $job->{parent_group}, 'Foo', 'parent group name was shown correctly';
    is $job->{parent_group_id}, $parent_group_id, 'parent group id was shown correctly';
};

subtest 'server-side limit has precedence over user-specified limit' => sub {
    my $limits = OpenQA::App->singleton->config->{misc_limits};
    $limits->{generic_max_limit} = 5;
    $limits->{generic_default_limit} = 2;

    $t->get_ok('/api/v1/jobs?limit=10', 'query with exceeding user-specified limit for jobs')->status_is(200);
    my $jobs = $t->tx->res->json->{jobs};
    is ref $jobs, 'ARRAY', 'data returned (1)' and is scalar @$jobs, 5, 'maximum limit for jobs is effective';

    $t->get_ok('/api/v1/jobs?limit=3', 'query with user-specified limit for jobs')->status_is(200);
    $jobs = $t->tx->res->json->{jobs};
    is ref $jobs, 'ARRAY', 'data returned (2)' and is scalar @$jobs, 3, 'user limit for jobs is effective';

    $t->get_ok('/api/v1/jobs?latest=1&limit=2', 'query with user-specified limit for latest jobs')->status_is(200);
    $jobs = $t->tx->res->json->{jobs};
    is ref $jobs, 'ARRAY', 'data returned (3)' and is scalar @$jobs, 2, 'user limit for jobs is effective (latest)';

    $t->get_ok('/api/v1/jobs', 'query with (low) default limit for jobs')->status_is(200);
    $jobs = $t->tx->res->json->{jobs};
    is ref $jobs, 'ARRAY', 'data returned (4)' and is scalar @$jobs, 2, 'default limit for jobs is effective';
};

# delete the job with a registered job module
$t->delete_ok('/api/v1/jobs/99937')->status_is(200);
$t->get_ok('/api/v1/jobs/99937')->status_is(404);

done_testing();
