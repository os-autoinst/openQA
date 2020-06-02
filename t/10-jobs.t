#!/usr/bin/env perl

# Copyright (C) 2014-2020 SUSE LLC
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
use lib "$FindBin::Bin/lib";
use autodie ':all';
use Encode;
use File::Copy;
use OpenQA::Jobs::Constants;
use OpenQA::Utils 'resultdir';
use OpenQA::Test::Case;
use Test::MockModule 'strict';
use Test::Mojo;
use Mojo::JSON 'decode_json';
use Test::Warnings ':report_warnings';
use Mojo::File qw(path tempdir);
use Mojo::IOLoop::ReadWriteProcess;
use OpenQA::Test::Utils 'redirect_output';
use OpenQA::Parser::Result::OpenQA;
use OpenQA::Parser::Result::Test;
use OpenQA::Parser::Result::Output;

my $schema = OpenQA::Test::Case->new->init_data;
my $t      = Test::Mojo->new('OpenQA::WebAPI');
my $jobs   = $t->app->schema->resultset("Jobs");

# for "investigation" tests
my $job_mock     = Test::MockModule->new('OpenQA::Schema::Result::Jobs', no_auto => 1);
my $fake_git_log = 'deadbeef Break test foo';
$job_mock->redefine(git_log_diff => sub { $fake_git_log });

is($jobs->latest_build, '0091', 'can find latest build from jobs');
is($jobs->latest_build(version => 'Factory', distri => 'opensuse'), '0048@0815', 'latest build for non-integer build');
is($jobs->latest_build(version => '13.1', distri => 'opensuse'), '0091', 'latest build for different version differs');

my @latest = $jobs->latest_jobs;
my @ids    = map { $_->id } @latest;
# These two jobs have later clones in the fixture set, so should not appear
ok(grep(!/^(99962|99945)$/, @ids), 'jobs with later clones do not show up in latest jobs');
# These are the later clones, they should appear
ok(grep(/^99963$/, @ids), 'cloned jobs appear as latest job');
ok(grep(/^99946$/, @ids), 'cloned jobs appear as latest job (2nd)');

my %settings = (
    DISTRI  => 'Unicorn',
    FLAVOR  => 'pink',
    VERSION => '42',
    BUILD   => '666',
    ISO     => 'whatever.iso',
    MACHINE => "RainbowPC",
    ARCH    => 'x86_64',
);

sub _job_create {
    my $job = $schema->resultset('Jobs')->create_from_settings(@_);
    # reload all values from database so we can check against default values
    $job->discard_changes;
    return $job;
}

subtest 'has_dependencies' => sub {
    ok($jobs->find(99961)->has_dependencies,  'positive case: job is parent');
    ok($jobs->find(99963)->has_dependencies,  'positive case: job is child');
    ok(!$jobs->find(99946)->has_dependencies, 'negative case');
};

subtest 'has_modules' => sub {
    ok($jobs->find(99937)->has_modules,  'positive case');
    ok(!$jobs->find(99926)->has_modules, 'negative case');
};

subtest 'name/label/scenario and description' => sub {
    my $job = $schema->resultset('Jobs')->find(99926);
    is $job->name,          'opensuse-Factory-staging_e-x86_64-Build87.5011-minimalx@32bit', 'job name';
    is $job->label,         'minimalx@32bit',                                                'job label';
    is $job->scenario,      undef,                                                           'test scenario';
    is $job->scenario_name, 'opensuse-Factory-staging_e-x86_64-minimalx@32bit',              'test scenario name';
    is $job->scenario_description, undef, 'return undef if no description';

    my $minimalx_testsuite = $schema->resultset('TestSuites')->create(
        {
            name        => 'minimalx',
            description => 'foobar',
        });
    is($job->scenario_description, 'foobar', 'description returned');
    $minimalx_testsuite->delete;
};

subtest 'hard-coded initial job module statistics consistent; no automatic handling via DBIx hooks interferes' => sub {
    my $job     = $jobs->find(99946);
    my $modules = $job->modules;
    is($job->passed_module_count,     $modules->search({result => PASSED})->count,     'number of passed modules');
    is($job->softfailed_module_count, $modules->search({result => SOFTFAILED})->count, 'number of softfailed modules');
    is($job->failed_module_count,     $modules->search({result => FAILED})->count,     'number of failed modules');
    is($job->skipped_module_count,    $modules->search({result => SKIPPED})->count,    'number of skipped modules');
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
    is($job->result,                  OpenQA::Jobs::Constants::PASSED, 'job result is passed');
    is($job->passed_module_count,     4,                               'number of passed modules incremented');
    is($job->softfailed_module_count, 0,                               'number of softfailed modules not incremented');
    is($job->failed_module_count,     0,                               'number of failed modules not incremented');
    is($job->skipped_module_count,    0,                               'number of skipped modules not incremented');
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
    is($job->result,                  OpenQA::Jobs::Constants::FAILED, 'job result is failed');
    is($job->passed_module_count,     4,                               'number of passed modules incremented');
    is($job->softfailed_module_count, 0,                               'number of softfailed modules not incremented');
    is($job->failed_module_count,     0,                               'number of failed modules not incremented');
    is($job->skipped_module_count,    1,                               'number of skipped modules incremented');
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
    is($job->result,                  OpenQA::Jobs::Constants::FAILED, 'job result is failed');
    is($job->passed_module_count,     3,                               'number of passed modules incremented');
    is($job->softfailed_module_count, 0,                               'number of softfailed modules not incremented');
    is($job->failed_module_count,     1,                               'number of failed modules incremented');
    is($job->skipped_module_count,    0,                               'number of skipped modules not incremented');
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
    is($job->result,                  OpenQA::Jobs::Constants::SOFTFAILED, 'job result is softfailed');
    is($job->passed_module_count,     3,                                   'number of passed modules incremented');
    is($job->softfailed_module_count, 1,                                   'number of softfailed modules incremented');
    is($job->failed_module_count,     0,                                   'number of failed modules not incremented');
    is($job->skipped_module_count,    0,                                   'number of skipped modules not incremented');
};

subtest 'inserting the same module twice keeps the job module statistics intact' => sub {
    my $job               = _job_create({%settings, TEST => 'TEST2'});
    my @test_module_names = (qw(a b b c));
    my @test_modules      = map { {name => $_, category => $_, script => $_, flags => {}} } @test_module_names;
    $job->insert_test_modules(\@test_modules);
    $job->update_module($_, {result => 'ok', details => []}) for @test_module_names;
    $job->discard_changes;

    subtest 'all modules passed; b not accounted twice' => sub {
        is($job->passed_module_count,     3, 'number of passed modules incremented');
        is($job->softfailed_module_count, 0, 'number of softfailed modules still zero');
        is($job->failed_module_count,     0, 'number of failed modules still zero');
        is($job->skipped_module_count,    0, 'number of skipped modules still zero');
    };
};

subtest 'Create custom job module' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'TEST1';
    my $job    = _job_create(\%_settings);
    my $result = OpenQA::Parser::Result::OpenQA->new(
        details => [{text => "Test-CUSTOM.txt", title => 'CUSTOM'}],
        name    => 'random',
        result  => 'fail',
        test    => OpenQA::Parser::Result::Test->new(name => 'CUSTOM', category => 'w00t!'));
    my $content = Encode::encode('UTF-8', 'Whatäver!');
    my $output  = OpenQA::Parser::Result::Output->new(file => 'Test-CUSTOM.txt', content => $content);

    is($job->failed_module_count, 0, 'no failed modules before');
    $job->custom_module($result => $output);
    $job->update;
    $job->discard_changes;
    is($job->passed_module_count,     0,                             'number of passed modules not incremented');
    is($job->softfailed_module_count, 0,                             'number of softfailed modules not incremented');
    is($job->failed_module_count,     1,                             'number of failed modules incremented');
    is($job->skipped_module_count,    0,                             'number of skipped modules not incremented');
    is($job->result,                  OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result,      OpenQA::Jobs::Constants::FAILED, 'job result is failed');
    is($job->result_size, length $content,                 'size of custom module taken into account');

    is(($job->failed_modules)->[0], 'CUSTOM', 'modules can have custom result');
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

subtest 'job with no modules => overall is failed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'J';
    my $job = _job_create(\%_settings);
    $job->update;
    $job->discard_changes;

    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::FAILED, 'job result is failed');
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
    $job->comments->create({text => 'bsc#101', user_id => 99901});

    $_settings{BUILD} = '667';
    $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {}});
    $job->update_module('a', {result => 'ok', details => [], dents => 1});
    $job->insert_module({name => 'b', category => 'b', script => 'b', flags => {}});
    $job->update_module('b', {result => 'ok', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result,   OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    is($job->comments, 0,                             'no comment');
    $job->done;
    $job->discard_changes;
    is($job->result,   OpenQA::Jobs::Constants::SOFTFAILED, 'job result is softfailed');
    is($job->comments, 1,                                   'one comment');
    like($job->comments->first->text, qr/\Qbsc#101\E/, 'right take over');

    $_settings{BUILD} = '668';
    $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {}});
    $job->update_module('a', {result => 'ok', details => [], dents => 1});
    $job->insert_module({name => 'b', category => 'b', script => 'b', flags => {}});
    $job->update_module('b', {result => 'fail', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result,   OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    is($job->comments, 0,                             'no comment');

    subtest 'additional investigation notes provided on new failed' => sub {
        path('t/data/last_good.json')->copy_to(path(($job->_previous_scenario_jobs)[0]->result_dir(), 'vars.json'));
        path('t/data/first_bad.json')->copy_to(path($job->result_dir(),                               'vars.json'));
        $job->done;
        is($job->result, OpenQA::Jobs::Constants::FAILED, 'job result is failed');
        ok(my $inv = $job->investigate, 'job can provide investigation details');
        ok($inv,                        'job provides failure investigation');
        is($inv->{last_good}, 99998, 'previous job identified as last good');
        like($inv->{diff_to_last_good}, qr/^\+.*BUILD.*668/m, 'diff for job settings is shown');
        unlike($inv->{diff_to_last_good}, qr/JOBTOKEN/, 'special variables are not included');
        is($inv->{test_log},    $fake_git_log, 'test git log is evaluated');
        is($inv->{needles_log}, $fake_git_log, 'needles git log is evaluated');
        $fake_git_log = '';
        ok($inv = $job->investigate, 'job investigation ok for no test changes');
        is($inv->{test_log}, 'No test changes recorded, test regression unlikely', 'git log with no test changes');
    };

};

subtest 'carry over for ignore_failure modules' => sub {
    my %_settings = %settings;
    $_settings{TEST}  = 'K';
    $_settings{BUILD} = '669';
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
    $job->comments->create({text => 'bsc#101', user_id => 99901});

    $_settings{BUILD} = '670';
    $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {ignore_failure => 1}});
    $job->update_module('a', {result => 'fail', details => []});
    $job->insert_module({name => 'b', category => 'b', script => 'b', flags => {}});
    $job->update_module('b', {result => 'ok', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result,   OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    is($job->comments, 0,                             'no comment');
    $job->done;
    $job->discard_changes;
    is($job->result,   OpenQA::Jobs::Constants::PASSED, 'job result is passed');
    is($job->comments, 1,                               'one comment');
    like($job->comments->first->text, qr/\Qbsc#101\E/, 'right take over');

    $_settings{BUILD} = '671';
    $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {ignore_failure => 1}});
    $job->update_module('a', {result => 'fail', details => []});
    $job->insert_module({name => 'b', category => 'b', script => 'b', flags => {}});
    $job->update_module('b', {result => 'fail', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result,   OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    is($job->comments, 0,                             'no comment');
    $job->done;
    $job->discard_changes;
    is($job->result,   OpenQA::Jobs::Constants::FAILED, 'job result is failed');
    is($job->comments, 0,                               'one comment with failure investigation');
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
        ['ok',       'skip',     OpenQA::Jobs::Constants::PASSED],
        ['softfail', 'skip',     OpenQA::Jobs::Constants::SOFTFAILED],
        ['fail',     'skip',     OpenQA::Jobs::Constants::FAILED],
        [undef,      'skip',     OpenQA::Jobs::Constants::FAILED],
        ['skip',     'skip',     OpenQA::Jobs::Constants::PASSED],
        ['skip',     'ok',       OpenQA::Jobs::Constants::PASSED],
        ['skip',     'softfail', OpenQA::Jobs::Constants::SOFTFAILED],
        ['skip',     'fail',     OpenQA::Jobs::Constants::FAILED],
        ['skip',     undef,      OpenQA::Jobs::Constants::FAILED],
    ];

    for my $tm (@{$test_matrix}) {
        my %_settings    = %settings;
        my @tm_str       = map { $_ // 'undef' } @{$tm};
        my %module_count = (ok => 0, softfail => 0, fail => 0, undef => 0, skip => 0);
        $module_count{$tm_str[0]} = $module_count{$tm_str[0]} + 1;
        $module_count{$tm_str[1]} = $module_count{$tm_str[1]} + 1;
        $_settings{TEST}          = 'SKIP_TEST_' . join('_', @tm_str);
        my $job = _job_create(\%_settings);
        $job->insert_module({name => 'a', category => 'a', script => 'a'});
        $job->update_module('a', {result => $tm->[0], details => []});
        $job->insert_module({name => 'b', category => 'b', script => 'b'});
        $job->update_module('b', {result => $tm->[1], details => []});
        $job->done;
        $job->discard_changes;
        is($job->result,                  $tm->[2],                sprintf('job result: %s + %s => %s', @tm_str));
        is($job->passed_module_count,     $module_count{ok},       'check number of passed modules');
        is($job->softfailed_module_count, $module_count{softfail}, 'check number of softfailed modules');
        is($job->failed_module_count,     $module_count{fail},     'check number of failed modules');
        is($job->skipped_module_count,    $module_count{undef},    'check number of skipped modules');
        is($job->externally_skipped_module_count, $module_count{skip}, 'check number of externally skipped modules');
    }
};

sub job_is_linked {
    my ($job) = @_;
    $job->discard_changes;
    my $comments = $job->comments;
    while (my $comment = $comments->next) {
        if (($comment->label // '') eq 'linked') {
            return 1;
        }
    }
    return 0;
}

subtest 'job is marked as linked if accessed from recognized referal' => sub {
    $t->app->config->{global}->{recognized_referers}
      = ['test.referer.info', 'test.referer1.info', 'test.referer2.info', 'test.referer3.info'];
    my %_settings = %settings;
    $_settings{TEST} = 'refJobTest';
    my $job    = _job_create(\%_settings);
    my $linked = job_is_linked($job);
    is($linked, 0, 'new job is not linked');
    $t->get_ok('/tests/' . $job->id => {Referer => 'http://test.referer.info'})->status_is(200);
    $linked = job_is_linked($job);
    is($linked, 1, 'job linked after accessed from known referer');

    $_settings{TEST} = 'refJobTest-step';
    $job = _job_create(\%_settings);

    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {}});
    my $module = $job->modules->find({name => 'a'});
    $job->update;
    $linked = job_is_linked($job);
    is($linked, 0, 'new job is not linked');
    $t->get_ok('/tests/' . $job->id . '/modules/' . $module->id . '/steps/1' => {Referer => 'http://test.referer.info'})
      ->status_is(302);
    $linked = job_is_linked($job);
    is($linked, 1, 'job linked after accessed from known referer');
};

subtest 'job is not marked as linked if accessed from unrecognized referal' => sub {
    $t->app->config->{global}->{recognized_referers}
      = ['test.referer.info', 'test.referer1.info', 'test.referer2.info', 'test.referer3.info'];
    my %_settings = %settings;
    $_settings{TEST} = 'refJobTest2';
    my $job    = _job_create(\%_settings);
    my $linked = job_is_linked($job);
    is($linked, 0, 'new job is not linked');
    $t->get_ok('/tests/' . $job->id => {Referer => 'http://unknown.referer.info'})->status_is(200);
    $linked = job_is_linked($job);
    is($linked, 0, 'job not linked after accessed from unknown referer');
};

subtest 'job set_running()' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'L';
    my $job = _job_create(\%_settings);
    $job->update({state => OpenQA::Jobs::Constants::ASSIGNED});
    is($job->set_running, 1,                                'job was set to running');
    is($job->state,       OpenQA::Jobs::Constants::RUNNING, 'job state is now on running');
    $job->update({state => OpenQA::Jobs::Constants::RUNNING});
    is($job->set_running, 1,                                'job already running');
    is($job->state,       OpenQA::Jobs::Constants::RUNNING, 'job state is now on running');
    $job->update({state => 'foobar'});
    is($job->set_running, 0,        'job not set to running');
    is($job->state,       'foobar', 'job state is foobar');
};

$t->get_ok('/t99946')->status_is(302)->header_like(Location => qr{tests/99946});

subtest 'delete job assigned as last use for asset' => sub {
    my $assets     = $t->app->schema->resultset('Assets');
    my $some_job   = $jobs->first;
    my $some_asset = $assets->first;
    my $asset_id   = $some_asset->id;

    # let the asset reference a job
    $some_asset->update({last_use_job_id => $some_job->id});

    # delete that job
    ok($some_job->delete,      'job deletion ok');
    ok(!$some_job->in_storage, 'job no in storage anymore');

    # assert whether asset is still present
    $some_asset = $assets->find($asset_id);
    ok($some_asset, 'asset still exists');
    is($some_asset->last_use_job_id, undef, 'last job unset');
};

subtest 'create result dir, delete logs' => sub {
    $ENV{OPENQA_BASEDIR} = my $base_dir = tempdir;
    path(resultdir)->make_path;

    # create job
    my $initially_assumed_result_size = 1000;
    my $job = $jobs->create({TEST => 'delete-logs', logs_present => 1, result_size => $initially_assumed_result_size});
    $job->discard_changes;
    my $result_dir = path($job->create_result_dir);
    ok(-d $result_dir, 'result directory created');

    # create fake results
    my $ulogs_dir    = path($result_dir, 'ulogs')->make_path;
    my $file_content = Encode::encode('UTF-8', 'this text is 26 bytes long');
    path($result_dir, $_)->spurt($file_content) for qw(autoinst-log.txt video.ogv serial0.txt serial_terminal.txt);
    my @ulogs = qw(bar.log foo.log);
    path($ulogs_dir, $_)->spurt($file_content) for @ulogs;
    is_deeply $job->test_uploadlog_list, \@ulogs, 'logs linked to job as uploaded';

    # delete logs
    $job->delete_logs;
    $job->discard_changes;

    # verify deletion and accounting
    is($job->logs_present, 0, 'logs not present anymore');
    is(
        $job->result_size,
        $initially_assumed_result_size - 6 * length($file_content),
        'deleted size substracted from result size'
    );
    is($result_dir->list_tree({hidden => 1})->size, 0, 'no more files left');
};

# continue testing with the usual base dir for test fixtures
$ENV{OPENQA_BASEDIR} = 't/data';

subtest 'modules are unique per job' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'X';
    my $job = _job_create(\%_settings);
    $job->insert_module({name => 'some_name', category => 'some_category', script => 'foo/bar.pm', flags => {}});
    $job->insert_module({name => 'some_name', category => 'some_category', script => 'foo/bar.pm', flags => {}});
    my @modules = $job->modules->all;
    is $modules[0]->name,   'some_name',  'right name';
    is $modules[0]->script, 'foo/bar.pm', 'right script';
    is $modules[1], undef, 'no second result';
};

subtest 'saving results' => sub {
    my %some_test_results    = (results => [], spare => 'me the details');
    my $arbitrary_job_module = $schema->resultset('JobModules')->first;
    $arbitrary_job_module->save_results(\%some_test_results);
    my $details_file = path($arbitrary_job_module->job->result_dir, 'details-' . $arbitrary_job_module->name . '.json');
    is_deeply(decode_json($details_file->slurp), \%some_test_results, 'overall structure of test results preserved');
};

done_testing();
