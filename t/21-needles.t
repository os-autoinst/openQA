#!/usr/bin/env perl

# Copyright 2016 Red Hat
# Copyright 2019-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Cwd qw(abs_path);
use OpenQA::Schema;
require OpenQA::Test::Database;
use OpenQA::Test::TimeLimit '10';
use OpenQA::Task::Needle::Scan;
use OpenQA::Needles qw(_locate_needle_for_ref);
use File::Find;
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Time::Seconds;
use Test::Output 'combined_like';
use Test::Mojo;
use Test::MockModule;
use OpenQA::Utils qw(ensure_timestamp_appended find_bug_number needledir testcasedir
  run_cmd_with_log run_cmd_with_log_return_error);
use OpenQA::Test::Utils 'setup_fullstack_temp_dir';
use Test::Warnings ':report_warnings';
use Date::Format 'time2str';

my %settings = (
    TEST => 'test',
    DISTRI => 'fedora',
    FLAVOR => 'DVD',
    VERSION => '25',
    BUILD => '20160916',
    ISO => 'whatever.iso',
    MACHINE => 'alpha',
    ARCH => 'x86_64',
);

my $mock_utils = Test::MockModule->new('OpenQA::Utils');
$mock_utils->redefine('run_cmd_with_log', sub { 1 });
$mock_utils->redefine('run_cmd_with_log_return_error', sub($cmd, %args) { return {status => 1, stdout => '0123456789abcdef0123456789abcdef01234567', stderr => 'Error message'} });
my $mock_jobs = Test::MockModule->new('OpenQA::Schema::Result::Jobs');

my $schema = OpenQA::Test::Database->new->create;
my $needledir_archlinux = 't/data/openqa/share/tests/archlinux/needles';
my $needledir_fedora = 't/data/openqa/share/tests/fedora/needles';
# create dummy job
my $job = $schema->resultset('Jobs')->create_from_settings(\%settings);
# create dummy module
$job->insert_module({name => 'a', category => 'a', script => 'a', flags => {}});
my $module = $job->modules->find({name => 'a'});
my $t = Test::Mojo->new('OpenQA::WebAPI');

sub process {
    return unless (m/.json$/);
    # add needle to database
    OpenQA::Schema::Result::Needles::update_needle($_, $module, 0);
}

# read needles from primary needledir
find({wanted => \&process, follow => 1, no_chdir => 1}, $needledir_fedora);
# read needles from another needledir
find({wanted => \&process, follow => 1, no_chdir => 1}, $needledir_archlinux);

my $needles = $schema->resultset('Needles');
my $needle_dirs = $schema->resultset('NeedleDirs');

subtest 'handling of last update' => sub {
    is($needles->count({last_updated => undef}), 0, 'all needles should have last_updated set');

    my $needle = $needles->find(
        {
            filename => 'test-rootneedle.json',
            'directory.path' => {-like => '%' . $needledir_archlinux},
        },
        {prefetch => 'directory'});
    my $diff = $needle->last_updated->subtract_datetime_absolute($needle->t_updated)->seconds;
    cmp_ok $diff, '<=', 2, 'last_updated initialized on creation';

    # fake timestamps to be in the past to observe a difference if the test runs inside the same wall-clock second
    my $t_created = time2str('%Y-%m-%dT%H:%M:%S', time - (ONE_DAY * 5));
    my $t_updated = time2str('%Y-%m-%dT%H:%M:%S', time - (ONE_DAY * 2.5));
    $needle->update({t_created => $t_created, last_updated => $t_created, t_updated => $t_updated});
    $needle->discard_changes;

    my $last_actual_update = $needle->last_updated;
    my $new_last_match = time2str('%Y-%m-%dT%H:%M:%S', time);
    $needle->update({last_matched_time => $new_last_match});
    $needle->discard_changes;
    is($needle->last_updated, $t_created, 'last_updated not altered');
    ok($t_updated lt $needle->t_updated, 't_updated still updated');
    is($needle->last_matched_time, $new_last_match, 'last match updated');

    my $other_needle
      = $needles->update_needle_from_editor($needle->directory->path, 'test-rootneedle', {tags => [qw(foo bar)]},);
    is($other_needle->dir_id, $needle->dir_id, 'directory has not changed');
    is($other_needle->filename, $needle->filename, 'filename has not changed');
    is($other_needle->id, $needle->id, 'updated the same needle');

    $needle->discard_changes;
    my $last_actual_update2 = $needle->last_updated;
    ok(
        $last_actual_update lt $last_actual_update2,
        "last_updated changed after updating needle from editor ($last_actual_update < $last_actual_update2)",
    );
};

sub needle_count ($filename, $path = '%fedora/needles') {
    $needles->search({filename => $filename})->search_related('directory', {path => {like => $path}})->count;
}

subtest 'querying needles' => sub {
    is $needles->count({filename => 'test-rootneedle.json'}), 2,
      'two files called test-rootneedle (should not be a problem as needledir differes)';
    is needle_count('test-rootneedle.json'), 1, 'one test-rootneedle needle in fedora/needles needledir';
    is needle_count('gnome/browser/test-nestedneedle-2.json'), 1,
      'one needle that has fedora/needles needledir and relative path in its filename';
    is needle_count('test-duplicate-needle.json'), 1,
      'there can be two needles with the same names in different directories (1)';
    is needle_count('installer/test-duplicate-needle.json'), 1,
      'there can be two needles with the same names in different directories (2)';
    is needle_count('test-kdeneedle.json', '%archlinux/needles/kde'), 1,
      'needledir for nested needles placed under non-project needledir';
    is $_->file_present, 1, 'file_present set to 1 (' . $_->path . ')' for $needles->all;
};

subtest 'needle scan' => sub {
    # create record in DB about non-existent needle
    $needles->create(
        {
            dir_id => $needle_dirs->find({path => {like => '%fedora/needles'}})->id,
            filename => 'test-nonexistent.json',
            last_seen_module_id => $module->id,
            last_matched_module_id => $module->id,
            file_present => 1
        });
    # check that it was created
    is $needles->count({filename => 'test-nonexistent.json'}), 1, 'needle created';
    is $needles->find({filename => 'test-nonexistent.json'})->file_present, 1,
      'needle assumed to be present by default';
    # update info about whether needles are present
    OpenQA::Task::Needle::Scan::_needles($t->app, undef);
    is $needles->find({filename => 'test-nonexistent.json'})->file_present, 0,
      'file_present set to 0 when scanning as it does not actually exist';
    is $needles->find({filename => 'installer/test-nestedneedle-1.json'})->file_present, 1,
      'existing needle still flagged as present';
};

subtest 'handling relative paths in update_needle' => sub {
    is($module->job->needle_dir,
        $needledir_fedora, 'needle dir of job deduced from settings (prerequisite for handling relative paths)');

    subtest 'handle needle path relative to share dir (legacy os-autoinst)' => sub {
        my $needle
          = OpenQA::Schema::Result::Needles::update_needle('tests/fedora/needles/test-rootneedle.json', $module, 0);
        is(
            $needle->path,
            abs_path('t/data/openqa/share/tests/fedora/needles/test-rootneedle.json'),
            'needle path correct'
        );
    };
    subtest 'handle needle path relative to needle dir' => sub {
        my $needle = OpenQA::Schema::Result::Needles::update_needle('test-rootneedle.json', $module, 0);
        is(
            $needle->path,
            abs_path('t/data/openqa/share/tests/fedora/needles/test-rootneedle.json'),
            'needle path correct'
        );
    };
    subtest 'handle needle path to non existent needle' => sub {
        my $needle;
        combined_like {
            $needle = OpenQA::Schema::Result::Needles::update_needle('test-does-not-exist.json', $module, 0);
        }
        qr/Needle file test-does-not-exist\.json not found within $needledir_fedora/, 'error logged';
        is($needle, undef, 'no needle created');
    };
};

subtest 'controller->_determine_needles_dir_for_job' => sub {
    my $controller = OpenQA::WebAPI::Controller::Step->new;
    $controller->app($t->app);
    local $settings{CASEDIR} = 'https://something#fragment';
    my $job = $schema->resultset('Jobs')->create_from_settings(\%settings);
    $job->create_result_dir;

    subtest 'checkout_needles_sha = no' => sub {
        $controller->app->config->{'scm git'} = {checkout_needles_sha => 'no'};
        my ($needle_dirs, $needles_var) = $controller->_determine_needles_dir_for_job($job);
        is($needle_dirs, undef, 'needles directory determined');
        is($needles_var, undef, 'needles var determined');
    };

    subtest 'checkout_needles_sha = yes' => sub {
        $controller->app->config->{'scm git'} = {checkout_needles_sha => 'yes'};
        my ($needle_dirs, $needles_var) = $controller->_determine_needles_dir_for_job($job);
        like($needle_dirs, qr|t/data/openqa/share/tests/fedora/needles$|, 'needles dirs is defined');
        is($needles_var->value, 'https://something#fragment', 'needles var is defined');
    };
};

setup_fullstack_temp_dir('21-needles');

subtest 'controller->_create_tmpdir_for_needles_refspec' => sub {
    my $controller = OpenQA::WebAPI::Controller::Step->new;
    $controller->app($t->app);
    $controller->app->config->{'scm git'} = {checkout_needles_sha => 'yes'};

    subtest 'without fragment and needles_git_hash in vars' => sub {
        local $settings{CASEDIR} = 'https://something';
        my $job = $schema->resultset('Jobs')->create_from_settings(\%settings);
        path($job->needle_dir)->make_path;
        $job->create_result_dir;
        my ($needle_dirs, $needles_var) = $controller->_determine_needles_dir_for_job($job);

        my $needle_refs = $controller->_create_tmpdir_for_needles_refspec($job);

        is($needle_dirs, $job->needle_dir, 'needles var is defined');
        is($needles_var->value, 'https://something', 'needles var is defined');
        is($needle_refs, undef, 'needles refs cannot be defined without fragment or vars.json');
    };

    subtest 'with vars' => sub {
        local $settings{CASEDIR} = 'https://something';
        my $job = $schema->resultset('Jobs')->create_from_settings(\%settings);
        path($job->needle_dir)->make_path;
        my $testresult_dir = $job->create_result_dir;
        my $vars_json = path($testresult_dir, 'vars.json');
        my $vars_json_content = '{"NEEDLES_GIT_HASH": "0123456789abcdef0123456789abcdef01234567"}';
        $vars_json->spew($vars_json_content);

        my $needle_refs = $controller->_create_tmpdir_for_needles_refspec($job);

        is($needle_refs, '0123456789abcdef0123456789abcdef01234567', 'needles refs is defined with vars.json');
    };

    subtest 'with fragment' => sub {
        local $settings{CASEDIR} = 'https://something#fragment';
        my $job = $schema->resultset('Jobs')->create_from_settings(\%settings);
        path($job->needle_dir)->make_path;
        my $testresult_dir = $job->create_result_dir;
        my $needle_refs = $controller->_create_tmpdir_for_needles_refspec($job);
        is($needle_refs, '0123456789abcdef0123456789abcdef01234567', 'needles refs is defined with a fragment');

        subtest '_locate_needle_for_ref' => sub {
            my $location_for_ref = _locate_needle_for_ref('test.json', $ENV{OPENQA_BASEDIR}, $needle_refs);
            is($location_for_ref, undef, 'locate needle fail if relative path not exists');
        };

    };
};

subtest 'needledir set by jsonfile_in_temp_dir' => sub {
    my $needles_dir = path($ENV{OPENQA_BASEDIR}, 'openqa/webui/cache/needle-refs');
    path($needles_dir)->make_path;
    my $pngfile = path($needles_dir . '/needle.png');
    my $jsonfile = path($needles_dir . '/needle.json');
    $jsonfile->spew('{"area": [{"x" : 123, "y" : 456}]}');
    my $controller = OpenQA::WebAPI::Controller::File->new;
    $controller->app($t->app);
    $controller->param(name => $pngfile);
    $controller->param(version => $settings{VERSION});
    $controller->param(distri => $settings{DISTRI});
    $controller->param(jsonfile => $jsonfile);

    $controller->needle;

    $t->get('/needles/' . $settings{DISTRI} . '/#needle')
      ->status_is(200);
    my $res = $t->name('needle_file')->to('file#needle');
    is($res, '', 'should fail');
    # is($res_json->{area}->[0]->{x}, 123, 'JSON response has correct x value');
    # is($res_json->{area}->[0]->{y}, 456, 'JSON response has correct y value');
};

done_testing;
