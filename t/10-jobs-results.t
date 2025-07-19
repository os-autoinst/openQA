#!/usr/bin/env perl

# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings ':report_warnings';
use Test::MockModule 'strict';
use Mojo::File qw(path tempdir);
use Mojo::JSON 'decode_json';
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Mojo::Base -signatures;
use autodie ':all';
use OpenQA::App;
use OpenQA::Jobs::Constants;
use OpenQA::Utils 'resultdir';
use OpenQA::Test::Case;
use OpenQA::Task::SignalGuard;
use OpenQA::Test::TimeLimit '30';
use OpenQA::WebAPI;

my $schema = OpenQA::Test::Case->new->init_data;
my $jobs = $schema->resultset('Jobs');
OpenQA::App->set_singleton(OpenQA::WebAPI->new);

my %settings = (
    DISTRI => 'Unicorn',
    FLAVOR => 'pink',
    VERSION => '42',
    ARCH => 'x86_64',
);

sub _job_create {
    my $job = $jobs->create_from_settings(@_);
    # reload all values from database so we can check against default values
    $job->discard_changes;
    return $job;
}

subtest 'Create custom job module' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'TEST1';
    my $job = _job_create(\%_settings);
    my $result = OpenQA::Parser::Result::OpenQA->new(
        details => [{text => 'Test-CUSTOM.txt', title => 'CUSTOM'}],
        name => 'random',
        result => 'fail',
        test => OpenQA::Parser::Result::Test->new(name => 'CUSTOM', category => 'w00t!'));
    my $content = Encode::encode('UTF-8', 'Whatäver!');
    my $output = OpenQA::Parser::Result::Output->new(file => 'Test-CUSTOM.txt', content => $content);

    is($job->failed_module_count, 0, 'no failed modules before');
    $job->custom_module($result => $output);
    $job->update;
    $job->discard_changes;
    is($job->passed_module_count, 0, 'number of passed modules not incremented');
    is($job->softfailed_module_count, 0, 'number of softfailed modules not incremented');
    is($job->failed_module_count, 1, 'number of failed modules incremented');
    is($job->skipped_module_count, 0, 'number of skipped modules not incremented');
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::FAILED, 'job result is failed');
    is($job->result_size, length $content, 'size of custom module taken into account');

    is(($job->failed_modules)->[0], 'CUSTOM', 'modules can have custom result');
};

subtest 'create result dir, delete results' => sub {
    $ENV{OPENQA_BASEDIR} = my $base_dir = tempdir;
    path(resultdir)->make_path;

    # create job
    my $initially_assumed_result_size = 1000;
    my $job = $jobs->create({TEST => 'delete-logs', logs_present => 1, result_size => $initially_assumed_result_size});
    $job->discard_changes;
    my $result_dir = path($job->create_result_dir);
    ok(-d $result_dir, 'result directory created');

    # create fake results
    my $ulogs_dir = path($result_dir, 'ulogs')->make_path;
    my $file_content = Encode::encode('UTF-8', 'this text is 26 bytes long');
    my @fake_results = qw(autoinst-log.txt video.ogv video.webm video_time.vtt serial0.txt serial_terminal.txt);
    path($result_dir, $_)->spew($file_content) for @fake_results;
    my @ulogs = qw(bar.log foo.log);
    path($ulogs_dir, $_)->spew($file_content) for @ulogs;
    is_deeply $job->test_uploadlog_list, \@ulogs, 'logs linked to job as uploaded';
    is_deeply $job->video_file_paths->map('basename')->to_array, [qw(video.ogv video.webm)], 'all videos considered';

    subtest 'delete logs' => sub {
        $job->delete_logs;
        $job->discard_changes;
        is $job->logs_present, 0, 'logs not present anymore';
        is $job->result_size, $initially_assumed_result_size - length($file_content) * (@fake_results + @ulogs),
          'deleted size subtracted from result size';
        is $result_dir->list_tree({hidden => 1})->size, 0, 'no more files left';
        is_deeply $job->video_file_paths->to_array, [], 'no more videos found'
          or always_explain $job->video_file_paths->to_array;
    };
    subtest 'delete only videos' => sub {
        $job = $jobs->create({TEST => 'delete-logs', logs_present => 1, result_size => $initially_assumed_result_size});
        $job->discard_changes;
        ok -d ($result_dir = path($job->create_result_dir)), 'result directory created';
        path($result_dir, $_)->spew($file_content) for @fake_results;
        symlink(path($result_dir, 'video.webm'), my $symlink = path($result_dir, 'video.mkv'))
          or die "Unable to create symlink: $!";
        my $symlink_size = $symlink->lstat->size;
        $job->delete_videos;
        $job->discard_changes;
        is $job->logs_present, 1, 'logs still considered present';
        is $job->result_size, $initially_assumed_result_size - length($file_content) * 3 - $symlink_size,
          'deleted size subtracted from result size';
        is_deeply $job->video_file_paths->to_array, [], 'no more videos found'
          or always_explain $job->video_file_paths->to_array;
        ok -e path($result_dir, $_), "$_ still present" for qw(autoinst-log.txt serial0.txt serial_terminal.txt);
    };
    subtest 'result_size does not become negative' => sub {
        my $job_mock = Test::MockModule->new('OpenQA::Schema::Result::Jobs', no_auto => 1);
        $job_mock->redefine(_delete_returning_size_from_array => 5000);
        $job->delete_logs;
        $job->delete_videos;
        $job->discard_changes;
        is $job->result_size, 0, 'result_size just 0, not negative';
    };

    # note: Deleting results is tested in 42-screenshots.t because the screenshots are the interesting part here.

    subtest 'archiving job' => sub {
        my $job = $jobs->create({TEST => 'to-be-archived'});
        $job->discard_changes;
        $job->create_result_dir;
        is $job->archived, 0, 'job not archived by default';
        is $job->archive, undef, 'early return if job has not been concluded yet';

        my $result_dir = path($job->result_dir);
        like $result_dir, qr|$base_dir/openqa/testresults/\d{5}/\d{8}-to-be-archived|,
          'normal result directory returned by default';
        $result_dir->child('subdir')->make_path->child('some-file')->spew('test');
        $job->update({state => DONE});
        $job->discard_changes;

        my $copy_mock = Test::MockModule->new('File::Copy::Recursive', no_auto => 1);
        $copy_mock->redefine(dircopy => sub { $! = 4; return 0 });
        throws_ok { $job->archive } qr/Unable to copy '.+' to '.+': .+/, 'error when copying archive handled';
        ok -d $result_dir, 'normal result directory still exists';
        undef $copy_mock;

        my $signal_guard = OpenQA::Task::SignalGuard->new(undef);
        my $archive_dir = $job->archive($signal_guard);
        ok -d $archive_dir, 'archive result directory created';
        ok !-d $result_dir, 'normal result directory removed';
        ok !$signal_guard->retry, 'signal guard retry disabled in the end';
        undef $signal_guard;

        $result_dir = path($job->result_dir);
        like $result_dir, qr|$base_dir/openqa/archive/testresults/\d{5}/\d{8}-to-be-archived|,
          'archive result directory returned if archived';
        is $result_dir->child('subdir')->make_path->child('some-file')->slurp, 'test', 'nested file moved';

        is $job->archive, undef, 'early return if job has already been archived';
    };
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
    is $modules[0]->name, 'some_name', 'right name';
    is $modules[0]->script, 'foo/bar.pm', 'right script';
    is $modules[1], undef, 'no second result';
};

subtest 'saving results' => sub {
    my %some_test_results = (results => [], spare => 'me the details');
    my $arbitrary_job_module = $schema->resultset('JobModules')->first;
    $arbitrary_job_module->save_results(\%some_test_results);
    my $details_file = path($arbitrary_job_module->job->result_dir, 'details-' . $arbitrary_job_module->name . '.json');
    is_deeply(decode_json($details_file->slurp), \%some_test_results, 'overall structure of test results preserved');
};

subtest 'loading results with missing file in details' => sub {
    my $some_test_results = {
        results => [
            {
                test_fqn => 'random:test',
                status => 'pass',
                environment => {},
                test => {
                    log => "\nabort01     1  TPASS  :  abort raised SIGIOT\n### TEST abort01 COMPLETE >>> 0",
                    duration => 0.233695723931305,
                    result => 'PASS'
                }}
        ],
        details => [
            {
                result => 'ok',
                text => 'before_test-1.txt',
                title => 'wait_serial'
            }]};

    my $arbitrary_job_module = $schema->resultset('JobModules')->first;
    $arbitrary_job_module->save_results($some_test_results);
    ok -f path($arbitrary_job_module->job->result_dir, 'details-' . $arbitrary_job_module->name . '.json'),
      'details file exists';
    $some_test_results->{details}[0]{text_data} = 'Unable to read before_test-1.txt.';
    is_deeply($arbitrary_job_module->results, $some_test_results);
};

done_testing();
