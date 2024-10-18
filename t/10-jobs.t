#!/usr/bin/env perl

# Copyright 2014-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

BEGIN {
    # increase coverage scale factor for timeout to account for the Minion jobs being executed
    $ENV{OPENQA_TEST_TIMEOUT_SCALE_COVER} = 3.5;
}

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Mojo::Base -signatures;
use autodie ':all';
use File::Copy;
use OpenQA::Jobs::Constants;
use OpenQA::Test::Case;
use Test::MockModule 'strict';
use Test::Mojo;
use Test::Warnings qw(:report_warnings warning);
use Mojo::File 'path';
use Mojo::JSON qw(decode_json encode_json);
use OpenQA::Test::Utils qw(perform_minion_jobs);
use OpenQA::Test::TimeLimit '30';

binmode(STDOUT, ":encoding(UTF-8)");

my $schema_name = OpenQA::Test::Database::generate_schema_name;
my $schema = OpenQA::Test::Case->new->init_data(
    fixtures_glob => '01-jobs.pl 05-job_modules.pl 06-job_dependencies.pl',
    schema_name => $schema_name
);
my $t = Test::Mojo->new('OpenQA::WebAPI');
my $jobs = $t->app->schema->resultset('Jobs');
my $users = $t->app->schema->resultset('Users');

# for "investigation" tests
my $fake_git_log = 'deadbeef Break test foo';

subtest 'handling of concurrent deletions in code updating jobs' => sub {
    ok my $job = $jobs->find(99927), 'job exists in first place';

    # delete job "in the middle" via another schema
    my $schema2 = OpenQA::Schema->connect($ENV{TEST_PG});
    $schema2->storage->on_connect_do("SET search_path TO \"$schema_name\"");
    $schema2->resultset('Jobs')->search({id => 99927})->delete;

    # update the job (so far only accounting the result size is covered)
    $job->discard_changes;
    is $job->id, 99927, 'job ID still accessible (despite deletion and discarding changes)';
    ok !$job->account_result_size(test => 123), 'no exception when accounting result size, just falsy return code';
};

my %settings = (
    DISTRI => 'Unicorn',
    FLAVOR => 'pink',
    VERSION => '42',
    BUILD => '666',
    ISO => 'whatever.iso',
    MACHINE => "RainbowPC",
    ARCH => 'x86_64',
);

sub _job_create {
    my $job = $jobs->create_from_settings(@_);
    # reload all values from database so we can check against default values
    $job->discard_changes;
    return $job;
}

subtest 'latest jobs' => sub {
    is $jobs->latest_build, '0091', 'can find latest build from jobs';
    is $jobs->latest_build(version => 'Factory', distri => 'opensuse'), '0048@0815', 'latest for non-integer build';
    is $jobs->latest_build(version => '13.1', distri => 'opensuse'), '0091', 'latest for different version differs';

    my @latest = $jobs->latest_jobs;
    my @ids = map { $_->id } @latest;
    # These two jobs have later clones in the fixture set, so should not appear
    ok(grep(!/^(99962|99945)$/, @ids), 'jobs with later clones do not show up in latest jobs');
    # These are the later clones, they should appear
    ok(grep(/^99963$/, @ids), 'cloned jobs appear as latest job');
    ok(grep(/^99946$/, @ids), 'cloned jobs appear as latest job (2nd)');
};


subtest 'has_dependencies' => sub {
    ok($jobs->find(99961)->has_dependencies, 'positive case: job is parent');
    ok($jobs->find(99963)->has_dependencies, 'positive case: job is child');
    ok(!$jobs->find(99946)->has_dependencies, 'negative case');
};

subtest 'has_modules' => sub {
    ok($jobs->find(99937)->has_modules, 'positive case');
    ok(!$jobs->find(99926)->has_modules, 'negative case');
};

subtest 'name/label/scenario and description' => sub {
    my $job = $schema->resultset('Jobs')->find(99926);
    is $job->name, 'opensuse-Factory-staging_e-x86_64-Build87.5011-minimalx@32bit', 'job name';
    is $job->label, 'minimalx@32bit', 'job label';
    is $job->scenario, undef, 'test scenario';
    is $job->scenario_name, 'opensuse-Factory-staging_e-x86_64-minimalx@32bit', 'test scenario name';
    is $job->scenario_description, undef, 'return undef if no description';

    my $minimalx_testsuite = $schema->resultset('TestSuites')->create(
        {
            name => 'minimalx',
            description => 'foobar',
        });
    is($job->scenario_description, 'foobar', 'description returned');
    $minimalx_testsuite->delete;
};

subtest 'hard-coded initial job module statistics consistent; no automatic handling via DBIx hooks interferes' => sub {
    my $job = $jobs->find(99946);
    my $modules = $job->modules;
    is($job->passed_module_count, $modules->search({result => PASSED})->count, 'number of passed modules');
    is($job->softfailed_module_count, $modules->search({result => SOFTFAILED})->count, 'number of softfailed modules');
    is($job->failed_module_count, $modules->search({result => FAILED})->count, 'number of failed modules');
    is($job->skipped_module_count, $modules->search({result => SKIPPED})->count, 'number of skipped modules');
};

subtest 'job with all modules passed => overall is passsed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'A';
    my $job = _job_create(\%_settings);
    for my $i (qw(a b c d)) {
        $job->insert_module({name => $i, category => $i, script => $i, flags => {}});
        $job->update_module($i, {result => 'ok', details => []});
    }
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::PASSED, 'job result is passed');
    is($job->passed_module_count, 4, 'number of passed modules incremented');
    is($job->softfailed_module_count, 0, 'number of softfailed modules not incremented');
    is($job->failed_module_count, 0, 'number of failed modules not incremented');
    is($job->skipped_module_count, 0, 'number of skipped modules not incremented');
};

subtest 'job with one skipped module => overall is failed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'A';
    my $job = _job_create(\%_settings);
    $job->insert_module({name => 'e', category => 'e', script => 'e', flags => {}});
    $job->update_module('e', {result => 'none', details => []});
    for my $i (qw(a b c d)) {
        $job->insert_module({name => $i, category => $i, script => $i, flags => {}});
        $job->update_module($i, {result => 'ok', details => []});
    }
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::FAILED, 'job result is failed');
    is($job->passed_module_count, 4, 'number of passed modules incremented');
    is($job->softfailed_module_count, 0, 'number of softfailed modules not incremented');
    is($job->failed_module_count, 0, 'number of failed modules not incremented');
    is($job->skipped_module_count, 1, 'number of skipped modules incremented');
};

subtest 'job with at least one module failed => overall is failed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'B';
    my $job = _job_create(\%_settings);
    for my $i (qw(a b c d)) {
        $job->insert_module({name => $i, category => $i, script => $i, flags => {}});
        $job->update_module($i, {result => $i eq 'c' ? 'fail' : 'ok', details => []});
    }
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::FAILED, 'job result is failed');
    is($job->passed_module_count, 3, 'number of passed modules incremented');
    is($job->softfailed_module_count, 0, 'number of softfailed modules not incremented');
    is($job->failed_module_count, 1, 'number of failed modules incremented');
    is($job->skipped_module_count, 0, 'number of skipped modules not incremented');
};

subtest 'job with at least one softfailed and rest passed => overall is softfailed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'C';
    my $job = _job_create(\%_settings);
    for my $i (qw(a b c)) {
        $job->insert_module({name => $i, category => $i, script => $i, flags => {}});
        $job->update_module($i, {result => 'ok', details => []});
    }
    $job->insert_module({name => 'd', category => 'd', script => 'd', flags => {}});
    $job->update_module('d', {result => 'ok', details => [], dents => 1});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::SOFTFAILED, 'job result is softfailed');
    is($job->passed_module_count, 3, 'number of passed modules incremented');
    is($job->softfailed_module_count, 1, 'number of softfailed modules incremented');
    is($job->failed_module_count, 0, 'number of failed modules not incremented');
    is($job->skipped_module_count, 0, 'number of skipped modules not incremented');
};

subtest 'inserting the same module twice keeps the job module statistics intact' => sub {
    my $job = _job_create({%settings, TEST => 'TEST2'});
    my @test_module_names = (qw(a b b c));
    my @test_modules = map { {name => $_, category => $_, script => $_, flags => {}} } @test_module_names;
    $job->insert_test_modules(\@test_modules);
    $job->update_module($_, {result => 'ok', details => []}) for @test_module_names;
    $job->discard_changes;

    subtest 'all modules passed; b not accounted twice' => sub {
        is($job->passed_module_count, 3, 'number of passed modules incremented');
        is($job->softfailed_module_count, 0, 'number of softfailed modules still zero');
        is($job->failed_module_count, 0, 'number of failed modules still zero');
        is($job->skipped_module_count, 0, 'number of skipped modules still zero');
    };
};

subtest 'job with at least one failed module and one softfailed => overall is failed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'D';
    my $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {}});
    $job->update_module('a', {result => 'ok', details => []});
    $job->insert_module({name => 'b', category => 'b', script => 'b', flags => {}});
    $job->update_module('b', {result => 'fail', details => []});
    $job->insert_module({name => 'c', category => 'c', script => 'c', flags => {}});
    $job->update_module('c', {result => 'ok', details => [], dents => 1});
    $job->insert_module({name => 'd', category => 'd', script => 'd', flags => {}});
    $job->update_module('d', {result => 'ok', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::FAILED, 'job result is failed');
};

subtest 'job with all modules passed and at least one ignore_failure failed => overall passed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'E';
    my $job = _job_create(\%_settings);
    for my $i (qw(a b c)) {
        $job->insert_module({name => $i, category => $i, script => $i, flags => {}});
        $job->update_module($i, {result => 'ok', details => []});
    }
    $job->insert_module({name => 'd', category => 'd', script => 'd', flags => {ignore_failure => 1}});
    $job->update_module('d', {result => 'fail', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::PASSED, 'job result is passed');
};

subtest
'job with important modules passed and at least one softfailed and at least one ignore_failure failed => overall softfailed'
  => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'F';
    my $job = _job_create(\%_settings);
    for my $i (qw(a b)) {
        $job->insert_module({name => $i, category => $i, script => $i, flags => {}});
        $job->update_module($i, {result => 'ok', details => []});
    }
    $job->insert_module({name => 'c', category => 'c', script => 'c', flags => {}});
    $job->update_module('c', {result => 'ok', details => [], dents => 1});
    $job->insert_module({name => 'd', category => 'd', script => 'd', flags => {ignore_failure => 1}});
    $job->update_module('d', {result => 'fail', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::SOFTFAILED, 'job result is softfailed');
  };

subtest
'job with one "important" (old flag we now ignore) module failed and at least one ignore_failure passed => overall failed'
  => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'G';
    my $job = _job_create(\%_settings);
    for my $i (qw(a b c)) {
        $job->insert_module({name => $i, category => $i, script => $i, flags => {ignore_failure => 1}});
        $job->update_module($i, {result => 'ok', details => []});
    }
    $job->insert_module({name => 'd', category => 'd', script => 'd', flags => {important => 1}});
    $job->update_module('d', {result => 'fail', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::FAILED, 'job result is failed');
  };

subtest 'job with first ignore_failure failed and rest softfails => overall is softfailed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'H';
    my $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {ignore_failure => 1}});
    $job->update_module('a', {result => 'fail', details => []});
    $job->insert_module({name => 'b', category => 'b', script => 'b', flags => {important => 1}});
    $job->update_module('b', {result => 'ok', details => [], dents => 1});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::SOFTFAILED, 'job result is softfailed');
};

subtest 'job with one ignore_failure pass => overall is passed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'H';
    my $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {ignore_failure => 1}});
    $job->update_module('a', {result => 'ok', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::PASSED, 'job result is passed');
};

subtest 'job with one ignore_failure fail => overall is passed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'H';
    my $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {ignore_failure => 1}});
    $job->update_module('a', {result => 'fail', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::PASSED, 'job result is passed');
};

subtest 'job with at least one softfailed => overall is softfailed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'I';
    my $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {important => 1}});
    $job->update_module('a', {result => 'ok', details => []});
    $job->insert_module({name => 'b', category => 'b', script => 'b', flags => {}});
    $job->update_module('b', {result => 'ok', details => []});
    $job->insert_module({name => 'c', category => 'c', script => 'c', flags => {}});
    $job->update_module('c', {result => 'ok', details => [], dents => 1});
    $job->insert_module({name => 'd', category => 'd', script => 'd', flags => {}});
    $job->update_module('d', {result => 'ok', details => []});
    $job->update;
    $job->discard_changes;

    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::SOFTFAILED, 'job result is softfailed');
};

subtest 'job with no modules => overall is incomplete' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'J';
    my $job = _job_create(\%_settings);
    $job->update;
    $job->discard_changes;

    is $job->result, NONE, 'result is not yet set';
    $job->done;
    $job->discard_changes;
    is $job->result, INCOMPLETE, 'job result is incomplete';
};

subtest 'carry over, including soft-fails' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'K';
    my $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {}});
    $job->update_module('a', {result => 'ok', details => [], dents => 1});
    $job->insert_module({name => 'b', category => 'b', script => 'b', flags => {}});
    $job->update_module('b', {result => 'ok', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::SOFTFAILED, 'job result is softfailed');
    my $user = $users->create_user('foo');
    $job->comments->create({text => 'bsc#101', user_id => $user->id});

    $_settings{BUILD} = '667';
    $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {}});
    $job->update_module('a', {result => 'ok', details => [], dents => 1});
    $job->insert_module({name => 'b', category => 'b', script => 'b', flags => {}});
    $job->update_module('b', {result => 'ok', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    is($job->comments, 0, 'no comment');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::SOFTFAILED, 'job result is softfailed');
    is($job->comments, 1, 'one comment');
    like($job->comments->first->text, qr/\Qbsc#101\E/, 'right take over');

    $_settings{BUILD} = '668';
    $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {}});
    $job->update_module('a', {result => 'ok', details => [], dents => 1});
    $job->insert_module({name => 'b', category => 'b', script => 'b', flags => {}});
    $job->update_module('b', {result => 'fail', details => []});
    $job->update;
    $job->done;
    $job->discard_changes;

    $_settings{BUILD} = '669';
    $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {}});
    $job->update_module('a', {result => 'ok', details => [], dents => 1});
    $job->insert_module({name => 'b', category => 'b', script => 'b', flags => {}});
    $job->update_module('b', {result => 'fail', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    is($job->comments, 0, 'no comment');

    subtest 'additional investigation notes provided on new failed' => sub {
        my $job_mock = Test::MockModule->new('OpenQA::Schema::Result::Jobs', no_auto => 1);
        my $got_limit = 0;
        my $got_diff_limit = 0;
        $job_mock->redefine(
            git_log_diff => sub ($self, $dir, $range, $limit) {
                $got_limit = $limit;
                return $fake_git_log;
            });
        $job_mock->redefine(
            git_diff => sub ($self, $dir, $range, $limit = undef) {
                $got_diff_limit = $limit;
                return $fake_git_log;
            });
        path('t/data/last_good.json')->copy_to(path(($job->_previous_scenario_jobs)[1]->result_dir(), 'vars.json'));
        path('t/data/first_bad.json')->copy_to(path($job->result_dir(), 'vars.json'));
        path('t/data/last_good_packages.txt')
          ->copy_to(path(($job->_previous_scenario_jobs)[1]->result_dir(), 'worker_packages.txt'));
        path('t/data/first_bad_packages.txt')->copy_to(path($job->result_dir(), 'worker_packages.txt'));
        $job->done;
        is($job->result, OpenQA::Jobs::Constants::FAILED, 'job result is failed');
        ok(my $inv = $job->investigate, 'job can provide investigation details');
        ok($inv, 'job provides failure investigation');
        is(ref(my $last_good = $inv->{last_good}), 'HASH', 'previous job identified as last good and it is a hash');
        is($last_good->{text}, 99997, 'last_good hash has the text');
        is($last_good->{type}, 'link', 'last_good hash has the type');
        is($last_good->{link}, '/tests/99997', 'last_good hash has the correct link');
        is(ref(my $first_bad = $inv->{first_bad}), 'HASH', 'previous job identified as first bad and it is a hash');
        is($first_bad->{text}, 99998, 'first_bad hash has the text');
        is($first_bad->{type}, 'link', 'first_bad hash has the type');
        is($first_bad->{link}, '/tests/99998', 'first_bad hash has the correct link');
        like($inv->{diff_to_last_good}, qr/^\+.*BUILD.*669/m, 'diff for job settings is shown');
        unlike($inv->{diff_to_last_good}, qr/JOBTOKEN/, 'special variables are not included');
        like($inv->{diff_packages_to_last_good}, qr/^\+python/m, 'diff packages for job is shown');
        is($inv->{test_log}, $fake_git_log, 'test git log is evaluated');
        is($inv->{needles_log}, $fake_git_log, 'needles git log is evaluated');
        $fake_git_log = '';
        ok($inv = $job->investigate, 'job investigation ok for no test changes');
        is($inv->{test_log}, 'No test changes recorded, test regression unlikely', 'git log with no test changes');

        subtest 'investigation can display test_log with git stats when one commit' => sub {
            $fake_git_log = "\nqwertyuio0 test0\n mylogfile0 | 1 +\n 1 file changed, 1 insertion(+)\nqwertyuio1";
            ok($inv = $job->investigate, 'job investigation ok with test changes');
            my $actual_lines = split(/\n/, $inv->{test_log});
            my $expected_lines = 5;
            is($actual_lines, $expected_lines, 'test_log have correct number of lines');
            like($inv->{test_log}, qr/^.*file changed/m, 'git log with test changes');
        };
        subtest 'investigation can display test_log with git stats when more than one commit' => sub {
            $got_limit = 0;
            $fake_git_log
              = "\nqwertyuio0 test0\n mylogfile0 | 1 +\n 1 file changed, 1 insertion(+)\nqwertyuio1 test1\n mylogfile1 | 1 +\n 1 file changed, 1 insertion(+)\n";
            ok($inv = $job->investigate(git_limit => 23), 'job investigation ok with test changes');
            my $actual_lines = split(/\n/, $inv->{test_log});
            my $expected_lines = 7;
            is($actual_lines, $expected_lines, 'test_log have correct number of lines');
            like($inv->{test_log}, qr/^.*file changed/m, 'git log with test changes');
            is $got_limit, 23, 'git_limit was correctly passed';
        };
    };

    subtest 'vars.json with a UNKNOWN TEST_GIT_HASH' => sub {
        path('t/data/first_bad.json')->copy_to(path($job->result_dir(), 'vars.json'));
        my $last_good_path = path(($job->_previous_scenario_jobs)[1]->result_dir(), 'vars.json');
        path('t/data/last_good.json')->copy_to($last_good_path);
        my $last_good_vars = decode_json $last_good_path->slurp;
        $last_good_vars->{TEST_GIT_HASH} = 'UNKNOWN';
        $last_good_vars->{NEEDLES_GIT_HASH} = 'UNKNOWN';
        $last_good_path->spew(encode_json $last_good_vars);
        ok my $inv = $job->investigate, 'job can provide investigation details';
        is ref(my $last_good = $inv->{last_good}), 'HASH', 'previous job identified as last good and it is a hash';
        is $last_good->{link}, '/tests/99997', 'last_good hash has the correct link';
        like $inv->{test_log}, qr/Invalid range UNKNOWN..c65/, 'test_log has message about invalid range';
        like $inv->{test_diff_stat}, qr/Invalid range UNKNOWN..c65/, 'test_diff_stat has message about invalid range';
    };

    subtest 'No vars.json' => sub {
        unlink path($job->result_dir(), 'vars.json');
        my $last_good_path = path(($job->_previous_scenario_jobs)[1]->result_dir(), 'vars.json');
        path('t/data/last_good.json')->copy_to($last_good_path);
        ok my $inv = $job->investigate, 'Minimal investigation info is shown';
        is ref(my $last_good = $inv->{last_good}), 'HASH', 'previous job identified as last good and it is a hash';
        is $last_good->{link}, '/tests/99997', 'last_good hash has the correct link';
    };

    subtest 'vars.json of last good already deleted' => sub {
        path('t/data/first_bad.json')->copy_to(path($job->result_dir(), 'vars.json'));
        unlink path(($job->_previous_scenario_jobs)[1]->result_dir(), 'vars.json');
        ok my $inv = $job->investigate, 'job can provide investigation details';
        is ref(my $last_good = $inv->{last_good}), 'HASH', 'previous job identified as last good and it is a hash';
        is $inv->{diff_to_last_good}, undef, 'diff_to_last_good does not exist';
        is $last_good->{link}, '/tests/99997', 'last_good hash has the correct link';
        like($inv->{diff_packages_to_last_good}, qr/^\+python/m, 'diff packages for job is shown');
    };

    subtest 'external hook is called on done job if specified' => sub {
        my $task_mock = Test::MockModule->new('OpenQA::Task::Job::HookScript', no_auto => 1);
        $task_mock->redefine(
            _run_hook => sub ($hook, $openqa_job_id, $timeout, $kill_timeout) {
                my $openqa_job = $t->app->schema->resultset('Jobs')->find($openqa_job_id);
                $openqa_job->update({reason => "timeout --kill-after=$kill_timeout $timeout $hook"}) if $hook;
            });
        $job->done;
        perform_minion_jobs($t->app->minion);
        $job->discard_changes;
        is($job->reason, undef, 'no hook is called by default');
        $ENV{OPENQA_JOB_DONE_HOOK_INCOMPLETE} = 'should not be called';
        $job->done;
        perform_minion_jobs($t->app->minion);
        $job->discard_changes;
        is($job->reason, undef, 'hook not called if result does not match');
        $ENV{OPENQA_JOB_DONE_HOOK_FAILED} = 'true';
        $ENV{OPENQA_JOB_DONE_HOOK_TIMEOUT} = '10m';
        $ENV{OPENQA_JOB_DONE_HOOK_KILL_TIMEOUT} = '5s';
        $job->done;
        perform_minion_jobs($t->app->minion);
        $job->discard_changes;
        is($job->reason, 'timeout --kill-after=5s 10m true', 'hook called if result matches');
        $job->update({reason => undef});

        delete $ENV{OPENQA_JOB_DONE_HOOK_FAILED};
        delete $ENV{OPENQA_JOB_DONE_HOOK_TIMEOUT};
        delete $ENV{OPENQA_JOB_DONE_HOOK_KILL_TIMEOUT};
        my $hooks = ($t->app->config->{hooks} //= {});
        $hooks->{job_done_hook_failed} = 'echo hook called';
        $task_mock->unmock_all;
        $job->settings->create({key => '_TRIGGER_JOB_DONE_HOOK', value => '0'});
        $job->done;
        perform_minion_jobs($t->app->minion);
        my $notes = $t->app->minion->jobs({tasks => ['finalize_job_results']})->next->{notes};
        is($notes->{hook_id}, undef, 'hook not called despite matching result due to _TRIGGER_JOB_DONE_HOOK=0');

        $job->settings->search({key => '_TRIGGER_JOB_DONE_HOOK'})->delete;
        $job->discard_changes;
        $job->done;
        perform_minion_jobs($t->app->minion);
        my $job_info = $t->app->minion->jobs({tasks => ['hook_script']})->next;
        $notes = $job_info->{notes};
        is($notes->{hook_cmd}, 'echo hook called', 'real hook cmd in notes if result matches (1)');
        like($notes->{hook_result}, qr/hook called/, 'real hook cmd from config called if result matches (1)');
        is $notes->{hook_rc}, 0, 'exit code of the hook cmd is zero';
        $notes = $t->app->minion->jobs({tasks => ['finalize_job_results']})->next->{notes};
        is $notes->{hook_job}, $job_info->{id}, 'hook_script job is linked to finalize_result job';

        $hooks->{job_done_hook_failed} = 'echo oops && exit 23;';
        $job->done;
        perform_minion_jobs($t->app->minion);
        $job_info = $t->app->minion->jobs({tasks => ['hook_script']})->next;
        $notes = $job_info->{notes};
        is($notes->{hook_cmd}, 'echo oops && exit 23;', 'real hook cmd in notes if result matches (2)');
        like($notes->{hook_result}, qr/oops/, 'real hook cmd from config called if result matches (2)');
        is $notes->{hook_rc}, 23, 'exit code of the hook cmd is as expected';
        is $job_info->{retries}, 0, 'hook script has not been retried';

        delete $hooks->{job_done_hook_failed};
        $hooks->{job_done_hook} = 'echo generic hook';
        $job->done;
        perform_minion_jobs($t->app->minion);
        $notes = $t->app->minion->jobs({tasks => ['finalize_job_results']})->next->{notes};
        is($notes->{hook_job}, undef, 'generic hook not called by default');

        $hooks->{job_done_hook_enable_failed} = 1;
        $job->done;
        perform_minion_jobs($t->app->minion);
        $notes = $t->app->minion->jobs({tasks => ['hook_script']})->next->{notes};
        is($notes->{hook_cmd}, 'echo generic hook', 'generic hook cmd called if enabled for result');
        like($notes->{hook_result}, qr/generic hook/, 'generic hook cmd called if enabled for result');

        delete $hooks->{job_done_hook_enable_failed};
        $job->settings->create({key => '_TRIGGER_JOB_DONE_HOOK', value => '1'});
        $job->done;
        perform_minion_jobs($t->app->minion);
        $notes = $t->app->minion->jobs({tasks => ['hook_script']})->next->{notes};
        is($notes->{hook_cmd}, 'echo generic hook', 'generic hook cmd called if enabled via job setting');
        like($notes->{hook_result}, qr/generic hook/, 'generic hook cmd called if enabled via job setting');

        subtest 'Retry hook script with exit code 142' => sub {
            # Defaults (no retry)
            $hooks->{job_done_hook_failed} = 'echo retried && exit 143;';
            $job->discard_changes;
            $job->done;
            perform_minion_jobs($t->app->minion);
            $job_info = $t->app->minion->jobs({tasks => ['hook_script']})->next;
            is_deeply($job_info->{args}[2],
                {delay => 60, retries => 1440, skip_rc => 142, kill_timeout => '30s', timeout => '5m'});
            $notes = $job_info->{notes};
            is($notes->{hook_cmd}, 'echo retried && exit 143;', 'real hook cmd in notes if result matches (3)');
            like($notes->{hook_result}, qr/retried/, 'real hook cmd from config called if result matches (3)');
            is $notes->{hook_rc}, 143, 'exit code of the hook cmd is as expected';
            is $job_info->{retries}, 0, 'hook script has not been retried';

            # Environment variables (retry without delay)
            local $ENV{OPENQA_JOB_DONE_HOOK_DELAY} = 0;
            local $ENV{OPENQA_JOB_DONE_HOOK_RETRIES} = 2;
            local $ENV{OPENQA_JOB_DONE_HOOK_SKIP_RC} = 143;
            $job->discard_changes;
            $job->done;
            perform_minion_jobs($t->app->minion);
            $job_info = $t->app->minion->jobs({tasks => ['hook_script']})->next;
            is_deeply($job_info->{args}[2],
                {delay => 0, retries => 2, skip_rc => 143, kill_timeout => '30s', timeout => '5m'});
            $notes = $job_info->{notes};
            is($notes->{hook_cmd}, 'echo retried && exit 143;', 'real hook cmd in notes if result matches (4)');
            like($notes->{hook_result}, qr/retried/, 'real hook cmd from config called if result matches (4)');
            is $notes->{hook_rc}, 143, 'exit code of the hook cmd is as expected';
            is $job_info->{retries}, 2, 'hook script has been retried';

            # Job settings (retry without delay)
            delete $ENV{OPENQA_JOB_DONE_HOOK_DELAY};
            delete $ENV{OPENQA_JOB_DONE_HOOK_RETRIES};
            delete $ENV{OPENQA_JOB_DONE_HOOK_SKIP_RC};
            $job->discard_changes;
            $job->done;
            $job->settings->create({key => '_TRIGGER_JOB_DONE_DELAY', value => '0'});
            $job->settings->create({key => '_TRIGGER_JOB_DONE_RETRIES', value => '4'});
            $job->settings->create({key => '_TRIGGER_JOB_DONE_SKIP_RC', value => '143'});
            perform_minion_jobs($t->app->minion);
            $job_info = $t->app->minion->jobs({tasks => ['hook_script']})->next;
            is $job_info->{state}, 'finished', 'hook script has been retried without delay';
            is_deeply($job_info->{args}[2],
                {delay => 0, retries => 4, skip_rc => 143, kill_timeout => '30s', timeout => '5m'});
            $notes = $job_info->{notes};
            is($notes->{hook_cmd}, 'echo retried && exit 143;', 'real hook cmd in notes if result matches (4)');
            like($notes->{hook_result}, qr/retried/, 'real hook cmd from config called if result matches (4)');
            is $notes->{hook_rc}, 143, 'exit code of the hook cmd is as expected';
            is $job_info->{retries}, 4, 'hook script has been retried';

            # Defaults (retry with delay)
            $job->settings->search({key => '_TRIGGER_JOB_DONE_DELAY'})->delete;
            $job->settings->search({key => '_TRIGGER_JOB_DONE_RETRIES'})->delete;
            $job->settings->search({key => '_TRIGGER_JOB_DONE_SKIP_RC'})->delete;
            $hooks->{job_done_hook_failed} = 'echo delayed && exit 142;';
            $job->discard_changes;
            $job->done;
            perform_minion_jobs($t->app->minion);
            $job_info = $t->app->minion->jobs({tasks => ['hook_script']})->next;
            is $job_info->{state}, 'inactive', 'hook script has been retried with long delay';
            is_deeply($job_info->{args}[2],
                {delay => 60, retries => 1440, skip_rc => 142, kill_timeout => '30s', timeout => '5m'});
            $notes = $job_info->{notes};
            is($notes->{hook_cmd}, 'echo delayed && exit 142;', 'real hook cmd in notes if result matches (5)');
            like($notes->{hook_result}, qr/delayed/, 'real hook cmd from config called if result matches (5)');
            is $notes->{hook_rc}, 142, 'exit code of the hook cmd is as expected';
            is $job_info->{retries}, 1, 'hook script has been retried once because of delay';
        };
    };
};

subtest 'carry over for ignore_failure modules' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'K';
    $_settings{BUILD} = '670';
    my $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {ignore_failure => 1}});
    $job->update_module('a', {result => 'fail', details => []});
    $job->insert_module({name => 'b', category => 'b', script => 'b', flags => {}});
    $job->update_module('b', {result => 'ok', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::PASSED, 'job result is passed');
    my $user = $users->create_user('foo');
    $job->comments->create({text => 'bsc#101', user_id => $user->id});

    $_settings{BUILD} = '671';
    $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {ignore_failure => 1}});
    $job->update_module('a', {result => 'fail', details => []});
    $job->insert_module({name => 'b', category => 'b', script => 'b', flags => {}});
    $job->update_module('b', {result => 'ok', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    is($job->comments, 0, 'no comment');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::PASSED, 'job result is passed');
    is($job->comments, 1, 'one comment');
    like($job->comments->first->text, qr/\Qbsc#101\E/, 'right take over');

    $_settings{BUILD} = '672';
    $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {ignore_failure => 1}});
    $job->update_module('a', {result => 'fail', details => []});
    $job->insert_module({name => 'b', category => 'b', script => 'b', flags => {}});
    $job->update_module('b', {result => 'fail', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    is($job->comments, 0, 'no comment');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::FAILED, 'job result is failed');
    is($job->comments, 0, 'one comment with failure investigation');
};

subtest 'job with only important passes => overall is passed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'L';
    my $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {important => 1}});
    $job->update_module('a', {result => 'ok', details => []});
    $job->insert_module({name => 'b', category => 'b', script => 'b', flags => {important => 1}});
    $job->update_module('b', {result => 'ok', details => []});
    $job->insert_module({name => 'c', category => 'c', script => 'c', flags => {important => 1}});
    $job->update_module('c', {result => 'ok', details => []});
    $job->insert_module({name => 'd', category => 'd', script => 'd', flags => {important => 1}});
    $job->update_module('d', {result => 'ok', details => []});
    $job->update;
    $job->discard_changes;

    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::PASSED, 'job result is passed');
};

subtest 'job with skipped modules' => sub {
    my $test_matrix = [
        ['ok', 'skip', OpenQA::Jobs::Constants::PASSED],
        ['softfail', 'skip', OpenQA::Jobs::Constants::SOFTFAILED],
        ['fail', 'skip', OpenQA::Jobs::Constants::FAILED],
        [undef, 'skip', OpenQA::Jobs::Constants::FAILED],
        ['skip', 'skip', OpenQA::Jobs::Constants::PASSED],
        ['skip', 'ok', OpenQA::Jobs::Constants::PASSED],
        ['skip', 'softfail', OpenQA::Jobs::Constants::SOFTFAILED],
        ['skip', 'fail', OpenQA::Jobs::Constants::FAILED],
        ['skip', undef, OpenQA::Jobs::Constants::FAILED],
    ];

    for my $tm (@{$test_matrix}) {
        my %_settings = %settings;
        my @tm_str = map { $_ // 'undef' } @{$tm};
        my %module_count = (ok => 0, softfail => 0, fail => 0, undef => 0, skip => 0);
        $module_count{$tm_str[0]} = $module_count{$tm_str[0]} + 1;
        $module_count{$tm_str[1]} = $module_count{$tm_str[1]} + 1;
        $_settings{TEST} = 'SKIP_TEST_' . join('_', @tm_str);
        my $job = _job_create(\%_settings);
        $job->insert_module({name => 'a', category => 'a', script => 'a'});
        $job->update_module('a', {result => $tm->[0], details => []});
        $job->insert_module({name => 'b', category => 'b', script => 'b'});
        $job->update_module('b', {result => $tm->[1], details => []});
        $job->done;
        $job->discard_changes;
        is($job->result, $tm->[2], sprintf('job result: %s + %s => %s', @tm_str));
        is($job->passed_module_count, $module_count{ok}, 'check number of passed modules');
        is($job->softfailed_module_count, $module_count{softfail}, 'check number of softfailed modules');
        is($job->failed_module_count, $module_count{fail}, 'check number of failed modules');
        is($job->skipped_module_count, $module_count{undef}, 'check number of skipped modules');
        is($job->externally_skipped_module_count, $module_count{skip}, 'check number of externally skipped modules');
    }
};

$t->get_ok('/t99946')->status_is(302)->header_like(Location => qr{tests/99946});

subtest 'delete job assigned as last use for asset' => sub {
    my $assets = $t->app->schema->resultset('Assets');
    my $some_job = $jobs->first;
    my $some_asset = $assets->first;
    my $asset_id = $some_asset->id;

    # let the asset reference a job
    $some_asset->update({last_use_job_id => $some_job->id});

    # delete that job
    ok($some_job->delete, 'job deletion ok');
    ok(!$some_job->in_storage, 'job no in storage anymore');

    # assert whether asset is still present
    $some_asset = $assets->find($asset_id);
    ok($some_asset, 'asset still exists');
    is($some_asset->last_use_job_id, undef, 'last job unset');
};

subtest 'job setting based retriggering' => sub {
    my $minion = $t->app->minion;
    my %_settings = %settings;
    $_settings{TEST} = 'no_retry';
    my $jobs_nr = $jobs->count;
    my $job = _job_create(\%_settings);
    is $jobs->count, $jobs_nr + 1, 'one more job';
    $job->done(result => FAILED);
    perform_minion_jobs($minion);
    is $jobs->count, $jobs_nr + 1, 'no additional job triggered (without retry)';
    is $job->clone_id, undef, 'no clone';
    $jobs_nr = $jobs->count;
    $_settings{TEST} = 'retry:2';
    $_settings{RETRY} = '2:bug#42';
    $job = _job_create(\%_settings);
    $job->done(result => PASSED);
    perform_minion_jobs($minion);
    is $jobs->count, $jobs_nr + 1, 'no additional job retriggered if PASSED (with retry)';
    $job->update({state => SCHEDULED, result => NONE});
    $job->done(result => USER_CANCELLED);
    perform_minion_jobs($minion);
    is $jobs->count, $jobs_nr + 1, 'no additional job retriggered if USER_CANCELLED (with retry)';
    $job->update({state => SCHEDULED, result => NONE});
    $job->done(result => OBSOLETED);
    perform_minion_jobs($minion);
    is $jobs->count, $jobs_nr + 1, 'no additional job retriggered if OBSOLETED (with retry)';
    my $get_jobs = sub ($task) {
        $minion->backend->pg->db->query(q{select * from minion_jobs where task = $1 order by id asc}, $task)->hashes;
        # note: Querying DB directly as `$minion->jobs({tasks => [$task]})` does not return parents.
    };
    my $restart_job_count_before = @{$get_jobs->('restart_job')};
    my $finalize_job_count_before = @{$get_jobs->('finalize_job_results')};
    $job->update({state => SCHEDULED, result => NONE});
    $job->done(result => FAILED);
    perform_minion_jobs($minion);
    is $jobs->count, $jobs_nr + 2, 'job retriggered as it FAILED (with retry)';
    $job->update;
    $job->discard_changes;
    is $job->comments->first->text, 'Restarting because RETRY is set to 2 (and only restarted 0 times so far)',
      'comment about retry';
    is $jobs->count, $jobs_nr + 2, 'job is automatically retriggered';
    my $restart_jobs = $get_jobs->('restart_job');
    my $finalize_jobs = $get_jobs->('finalize_job_results');
    is @$restart_jobs, $restart_job_count_before + 1, 'one restart job has been triggered';
    is @$finalize_jobs, $finalize_job_count_before + 1, 'one finalize job has been triggered';
    ok $finalize_jobs->[-1]->{lax}, 'finalize job would also run if restart job fails';
    is_deeply $finalize_jobs->[-1]->{parents}, [$restart_jobs->[-1]->{id}], 'finalize job triggered after restart job'
      or diag explain $finalize_jobs;
    my $first_job = $job;
    my $next_job_id = $job->id + 1;
    for (1 .. 2) {
        is $jobs->find({id => $next_job_id - 1})->clone_id, $next_job_id, "clone exists for retry nr. $_";
        $job = $jobs->find({id => $next_job_id});
        $jobs->find({id => $next_job_id})->done(result => FAILED);
        $job->update;
        perform_minion_jobs($minion);
        $job->discard_changes;
        ++$next_job_id;
    }
    is $jobs->count, $jobs_nr + 3, 'job with retry configured + 2 retries have been triggered';
    my $lastest_job = $jobs->find({id => $next_job_id - 1});
    is $lastest_job->clone_id, undef, 'no clone exists for last retry';
    is $first_job->latest_job->id, $lastest_job->id, 'found the latest job from the first job';
    is $lastest_job->latest_job->id, $lastest_job->id, 'found the latest job from latest job itself';
};

subtest '"race" between status updates and stale job detection' => sub {
    my $job = $jobs->create({TEST => 'test-job'});
    is_deeply $job->update_status({}), {result => 0}, 'status update rejected for scheduled job';
    is_deeply $job->update_status({uploading => 1}), {result => !!0},
      'status update rejected for scheduled job (uploading)';
    $job->discard_changes;
    is $job->state, SCHEDULED, 'job is still scheduled';

    $job->update({state => ASSIGNED});
    is $job->reschedule_state, 1, 'assigned job can be set back to scheduled';
    $job->discard_changes;
    is $job->state, SCHEDULED, 'job is in fact scheduled again';

    $job->update({state => ASSIGNED});
    my $update = $job->update_status({});
    is ref delete $update->{known_files}, 'ARRAY', 'known files returned';
    is ref delete $update->{known_images}, 'ARRAY', 'known images returned';
    is_deeply $update, {result => 1, job_result => INCOMPLETE}, 'status update accepted for assigned job (worker won)';
    $job->discard_changes;
    is $job->state, RUNNING, 'job is in fact running';
    is $job->reschedule_state, 0, 'running job can NOT be set back to scheduled';
    $job->discard_changes;
    is $job->state, RUNNING, 'job is still running';

    is_deeply $job->update_status({uploading => 1}), {result => 1}, 'job set to uploading';
    $job->discard_changes;
    is $job->state, UPLOADING, 'job is in fact uploading';
    is $job->update_status({})->{result}, 1, 'status updates still possible if uploading';
    $job->discard_changes;
    is $job->state, UPLOADING, 'job is still uploading';

    $job->update({state => CANCELLED});
    $update = $job->update_status({});
    is $update->{job_result}, 'incomplete', 'cancelled jobs will still get a status update';
};

is $t->app->minion->jobs({states => ['failed']})->total, 0, 'No unexpected failed minion background jobs';

subtest 'special cases when restarting job via Minion task' => sub {
    local $ENV{OPENQA_JOB_RESTART_ATTEMPTS} = 2;
    local $ENV{OPENQA_JOB_RESTART_DELAY} = 1;

    my $minion = $t->app->minion;
    my $test = sub ($args, $expected_state, $expected_result, $test, $task = 'restart_job') {
        subtest $test => sub {
            my $job_id = $minion->enqueue($task => $args);
            perform_minion_jobs($minion);
            my $job_info = $minion->job($job_id)->info;
            is $job_info->{state}, $expected_state, 'state';
            is $job_info->{result}, $expected_result, 'result';
            return $job_id;
        };
    };
    $test->([], 'failed', 'No job ID specified.',
        'error without openQA job ID (can happen if job is enqueued via CLI)');
    $test->(
        [45678], 'finished',
        'Job 45678 does not exist.',
        'no error if openQA job does not exist (maybe job has already been deleted)'
    );
    $test->(
        [99945], 'finished',
        'Specified job 99945 has already been cloned as 99946',
        'no error if openQA job already restarted but result still assigned accordingly'
    );

    # fake a different error
    my $job_mock = Test::MockModule->new('OpenQA::Schema::Result::Jobs');
    $job_mock->redefine(auto_duplicate => 'some error');

    # run into error assuming there's one retry attempt left
    $test->([99945], 'inactive', undef, 'retry scheduled if an error occurs and there are attempts left');

    # run into error assuming there are no retry attempts left
    local $ENV{OPENQA_JOB_RESTART_ATTEMPTS} = 1;
    $test->([99945], 'failed', 'some error', 'error if an error occurs and there are no attempts left');
};

subtest 'git log diff' => sub {
    my $job_mock = Test::MockModule->new('OpenQA::Schema::Result::Jobs', no_auto => 1);
    $job_mock->redefine(
        run_cmd_with_log_return_error => sub ($cmd, %opt) {
            my $rc = 0;
            my $stdout = '';
            if ("@$cmd" =~ m/rev-list --count/) {
                if ("@$cmd" =~ m/revlistfail/) { $stdout = "git failed"; $rc = 1; }
                elsif ("@$cmd" =~ m/nonumber/) { $stdout = "NaN"; }
                else { $stdout = 10; }
            }
            elsif ("@$cmd" =~ m/diff --stat/) {
                if ("@$cmd" =~ m/difffail/) { $stdout = "git failed"; $rc = 1; }
                else { $stdout = "2 files changed"; }
            }
            return {stdout => $stdout, return_code => $rc, stderr => ''};
        });
    my %_settings = %settings;
    $_settings{TEST} = 'L';
    my $job = _job_create(\%_settings);

    my $too_big = $job->git_diff('/foo', '123..456', 5);
    like $too_big, qr{Too many commits}, 'Too many commits';

    my $warning = warning {
        my $non_numeric = $job->git_diff('/foo', 'nonumber..123456', 10);
        like $non_numeric, qr{Cannot display diff because of a git problem}, 'rev-list --count returned no number';
    };
    like $warning, qr{returned non-numeric string}, 'rev-list --count returned no number - warning is logged';

    $warning = warning {
        my $fail = $job->git_diff('/foo', 'revlistfail..456', 10);
        like $fail, qr{Cannot display diff because of a git problem}, 'git rev-list exited with non-zero';
    };
    like $warning, qr{git failed}, 'git rev-list exited with non-zero - warning is logged';

    $warning = warning {
        my $fail = $job->git_diff('/foo', 'difffail..456', 10);
        like $fail, qr{Cannot display diff because of a git problem}, 'git diff exited with non-zero';
    };
    like $warning, qr{git failed}, 'git diff exited with non-zero - warning is logged';

    my $ok = $job->git_diff('/foo', '123..456', 10);
    like $ok, qr{2 files changed}, 'expected git_diff output';
};

subtest 'get all setting values for a job/key in a sorted array' => sub {
    my $job_settings = $schema->resultset('JobSettings');
    is_deeply $job_settings->all_values_sorted(99926, 'WORKER_CLASS'), [], 'empty array if key does not exist';
    $job_settings->create({job_id => 99926, key => 'WORKER_CLASS', value => $_}) for qw(foo bar bar baz);
    is_deeply $job_settings->all_values_sorted(99926, 'WORKER_CLASS'), [qw(bar baz foo)], 'all values returned';
};

subtest 'handling of array and unicode settings' => sub {
    my %s = %settings;
    $s{TEST} = 'array_setting_test';
    $s{ARRAY_SETTING} = ['value1', 'ä', '…'];
    my $job = _job_create(\%s);
    my $entry = $job->settings->find({key => 'ARRAY_SETTING'});
    ok $entry, 'ARRAY_SETTING exists in job settings';
    my $v = $entry->value;
    is ref($v), '', 'ARRAY_SETTING value is stored as a string';
    is $v, '["value1","ä","…"]', 'retrieved correctly encoded JSON array as string';
};

done_testing();
