#!/usr/bin/env perl
# Copyright 2020-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Log qw(log_error);
use OpenQA::Test::TimeLimit '10';
require OpenQA::Test::Database;
use OpenQA::Task::Job::Limit;
use OpenQA::Task::Utils qw(finish_job_if_disk_usage_below_percentage);
use OpenQA::Test::Utils qw(perform_minion_jobs run_gru_job);
use OpenQA::Utils qw(assetdir resultdir archivedir);
use Mojo::File qw(path tempdir);
use Mojo::Log;
use Test::Output qw(combined_like combined_from);
use Test::MockModule;
use Test::Mojo;
use Test::Warnings ':report_warnings';

my $schema = OpenQA::Test::Database->new->create(fixtures_glob => '03-users.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');
my $app = $t->app;
my $job_groups = $schema->resultset('JobGroups');
my $jobs = $schema->resultset('Jobs');
my $user = $schema->resultset('Users')->system;

$app->log(Mojo::Log->new(level => 'debug'));

sub job_log_like ($regex, $test_name) {
    my $job;
    combined_like { $job = run_gru_job($app, ensure_results_below_threshold => []) } $regex, $test_name;
    return $job;
}

subtest 'no minimum free disk space percentage for results configured' => sub {
    my $job = run_gru_job($app, ensure_results_below_threshold => []);
    is $job->{state}, 'finished', 'job considered successful';
    is $job->{result}, 'No minimum free disk space percentage configured', 'noop if no minimum configured';
};

# provide fake data for df
my $df_mock = Test::MockModule->new('Filesys::Df', no_auto => 1);
my %df_main_storage = (bavail => 11, blocks => 100);
my %df_archivedir = (bavail => 30, blocks => 100);
my %df_fake_data = (resultdir() => \%df_main_storage, archivedir() => \%df_archivedir);
my $mock_df = sub () {
    $df_mock->redefine(df => sub ($dir, @) { $df_fake_data{$dir} // \%df_main_storage });
};
$mock_df->();

subtest 'abort early if there is enough free disk space' => sub {

    $app->config->{misc_limits}->{result_cleanup_max_free_percentage} = 10;
    my $job = run_gru_job($app, limit_results_and_logs => []);
    is $job->{state}, 'finished', 'result cleanup still considered successful';
    like $job->{result},
      qr|Skipping.*/openqa/testresults.*exceeds configured percentage 10 % \(free percentage: 11 %\)|,
      'result cleanup aborted early';

    $app->config->{misc_limits}->{asset_cleanup_max_free_percentage} = 9;
    $job = run_gru_job($app, limit_assets => []);
    is $job->{state}, 'finished', 'asset cleanup still considered successful';
    like $job->{result},
      qr|Skipping.*/openqa/share/factory.*exceeds configured percentage 9 % \(free percentage: 11 %\)|,
      'asset cleanup aborted early';

    my @check_args = (job => $app->minion->job($job->{id}), setting => 'result_cleanup_max_free_percentage', dir => '');
    $job->{state} = undef;
    combined_like { ok !finish_job_if_disk_usage_below_percentage(@check_args, setting => 'foo'),
        'invalid setting ignored' } qr/Specified value.*will be ignored/, 'warning about invalid setting logged';

    $df_mock->redefine(df => sub { die 'df failed' });
    combined_like { ok !finish_job_if_disk_usage_below_percentage(@check_args), 'invalid df ignored' }
      qr/df failed.*Proceeding with cleanup/s, 'warning about invalid df logged';

    %df_main_storage = (bavail => 10, blocks => 100);
    $mock_df->();
    ok !finish_job_if_disk_usage_below_percentage(@check_args), 'cleanup done if not enough free disk space available';
    is $job->{state}, undef, 'job not finished when proceeding with cleanup';
};

$app->config->{misc_limits}->{result_cleanup_max_free_percentage} = 100;
$app->config->{misc_limits}->{asset_cleanup_max_free_percentage} = 100;

# mock the actual deletion of videos and results; it it tested elsewhere
my $job_mock = Test::MockModule->new('OpenQA::Schema::Result::Jobs');
my %gained_disk_space_by_deleting_video_of_job;
my %gained_disk_space_by_deleting_results_of_job;
my %gained_disk_space_by_deleting_screenshots_of_job;
my $available_bytes_mock = 0;
my $delete_video_hook;
$job_mock->redefine(
    delete_videos => sub {
        my $job_id = $_[0]->id;
        $delete_video_hook->($job_id) if $delete_video_hook;
        note "delete_videos called for job $job_id (bavail: $available_bytes_mock)";
        return $gained_disk_space_by_deleting_video_of_job{$job_id} // 0;
    });
$job_mock->redefine(
    delete_results => sub {
        my $job_id = $_[0]->id;
        note "delete_results called for job $job_id (bavail: $available_bytes_mock)";
        return (
            $gained_disk_space_by_deleting_results_of_job{$job_id} // 0,
            $gained_disk_space_by_deleting_screenshots_of_job{$job_id} // 0
        );
    });
# note: Not adjusting $available_bytes_mock in these functions because the code does not rely on df except for the initial check.

# turn on the cleanup
$app->config->{misc_limits}->{results_min_free_disk_space_percentage} = 20;

subtest 'df returns bad data' => sub {
    %df_main_storage = (bavail => 10, blocks => 5);
    my $expected_log = qr{Unable to determine disk usage of \'.*/data/openqa/testresults\'};
    my $job = job_log_like $expected_log, 'error logged';
    is $job->{state}, 'failed', 'job considered failed';
    like $job->{result}, $expected_log, 'error if df returns bad results';
};

subtest 'nothing to do' => sub {
    # setup: There is just enough disk space to not trigger the cleanup.
    %df_main_storage = (bavail => 40, blocks => 200);

    my $job = run_gru_job($app, ensure_results_below_threshold => []);
    is $job->{state}, 'finished', 'job considered successful';
    is $job->{result}, 'Done, nothing to do', 'nothing to do';
};

subtest 'no jobs present' => sub {
    # setup: There is just not enough disk space but we have not created any jobs so there's still nothing
    #        to cleanup.
    %df_main_storage = (bavail => 39, blocks => 200);

    my $job = run_gru_job($app, ensure_results_below_threshold => []);
    is $job->{state}, 'finished', 'job considered successful';
    is $job->{result}, 'Done, no jobs present', 'nothing to do';
};

# create a group with a comment so build 1234 is considered important
my $group_foo
  = $job_groups->create({name => 'foo', comments => [{user_id => $user->id, text => 'tag:1234:important'}]});
$group_foo->discard_changes;

# create one job belonging to the important build and one job which does not belong to it
my $group_id = $group_foo->id;
my $important_job = $jobs->create({TEST => 'important-job', BUILD => '1234', group_id => $group_id});
my $unimportant_job = $jobs->create({TEST => 'unimportant-job', BUILD => '0815', group_id => $group_id});
$important_job->discard_changes;
$unimportant_job->discard_changes;

my $important_job_id = $important_job->id;
my $unimportant_job_id = $unimportant_job->id;

subtest 'unable to make enough room; important job scheduled during the cleanup not touched' => sub {
    # setup: df and delete_videos are still mocked to be always stuck with not enough disk space except for
    #        an important job being scheduled while first video deletion happens. This new job must not be
    #        treated as an unimportant job just because it has only been added during the cleanup. To keep
    #        things simple it is instead supposed to be excluded from the cleanup.
    $delete_video_hook = sub {
        my $new_job = $jobs->create({TEST => 'another-important-job', BUILD => '1234', group_id => $group_id});
        $new_job->discard_changes;
        %gained_disk_space_by_deleting_video_of_job = ($new_job->id => 1);
        $delete_video_hook = undef;
    };

    my $job = job_log_like qr/
        Deleting\svideo\sof\sjob\s$unimportant_job_id.*Deleting\sresults\sof\sjob\s$unimportant_job_id.*
        Deleting\svideo\sof\simportant\sjob\s$important_job_id.*Deleting\sresults\sof\simportant\sjob\s$important_job_id
    /xs, 'cleanup steps in right order';
    is $job->{state}, 'failed', 'job considered failed';
    is $job->{result}, 'Unable to cleanup enough results from results dir', 'unable to make enough room';
};

my $new_job_id = $jobs->search({}, {rows => 1, order_by => {-desc => 'id'}})->first->id;
$delete_video_hook = undef;

subtest 'deleting videos from non-important jobs sufficient' => sub {
    # setup: delete_videos is now mocked to make it look like deleting the video of the unimportant job cleaned
    #        up enough free disk space.
    %gained_disk_space_by_deleting_video_of_job = ($unimportant_job_id => 1);

    my $job = job_log_like qr/Deleting\svideo\sof\sjob\s$unimportant_job_id/s, 'cleanup steps in right order';
    is $job->{state}, 'finished', 'job considered successful';
    is $job->{result}, 'Done with results dir after deleting videos from non-important jobs',
      'finished within expected step';
};

subtest 'job done triggers cleanup' => sub {
    my $old = $t->app->log->level;
    $t->app->log->level('error');
    $app->config->{minion_task_triggers}->{on_job_done} = ['limit_results_and_logs'];
    $important_job->done;
    perform_minion_jobs($t->app->minion);
    $important_job->discard_changes;
    my $minion_job = $t->app->minion->jobs->next;
    is($minion_job->{task}, 'limit_results_and_logs', 'cleanup triggered');

    $app->config->{minion_task_triggers}->{on_job_done} = [];
    $important_job->done;
    perform_minion_jobs($t->app->minion);
    $important_job->discard_changes;
    $minion_job = $t->app->minion->jobs->next;
    is($minion_job->{task}, 'finalize_job_results', 'no cleanup when not enabled');
    $t->app->log->level($old);
};

subtest 'deleting videos from important jobs sufficient' => sub {
    # setup: delete_videos is now mocked to make it look like deleting the video of the important job cleaned
    #        up enough free disk space.
    %gained_disk_space_by_deleting_video_of_job = ($important_job_id => 1);

    my $job;
    my $output = combined_from { $job = run_gru_job($app, ensure_results_below_threshold => []) };
    is $job->{state}, 'finished', 'job considered successful';
    is $job->{result}, 'Done with results dir after deleting videos from important jobs',
      'finished within expected step';
    like $output, qr/Deleting video of important job $important_job_id/, 'video of "old" important job deleted';
    unlike $output, qr/Deleting video.*$new_job_id/, 'video of job more recent important job not considered';
};

# assume video deletion does not do anything for us anymore to let the cleanup algorithm resort to cleaning up all results
%gained_disk_space_by_deleting_video_of_job = ();

# mock df for the subsequent tests so we would actually gain additional disk space over time
%df_main_storage = (bavail => 19, blocks => 100);

subtest 'deleting results from non-important jobs sufficient' => sub {
    # setup: delete_results is now mocked to make it look like deleting the results of the unimportant job cleaned
    #        up enough free disk space.
    %gained_disk_space_by_deleting_results_of_job = ($unimportant_job_id => 1);

    my $job = job_log_like qr/
        Deleting\svideo\sof\sjob\s$unimportant_job_id.*
        Deleting\sresults\sof\sjob\s$unimportant_job_id
    /xs, 'cleanup steps in right order';
    is $job->{state}, 'finished', 'job considered successful';
    is $job->{result}, 'Done with results dir after deleting results from non-important jobs',
      'finished within expected step';
};

subtest 'deleting results from important jobs sufficient' => sub {
    # setup: delete_results is now mocked to make it look like deleting the results of the important job cleaned
    #        up enough free disk space.
    %gained_disk_space_by_deleting_results_of_job = ($important_job_id => 1);

    my $job = job_log_like qr/
        Deleting\svideo\sof\sjob\s$unimportant_job_id.*
        Deleting\sresults\sof\sjob\s$unimportant_job_id.*
        Deleting\svideo\sof\simportant\sjob\s$important_job_id.*
        Deleting\svideo\sof\simportant\sjob\s$new_job_id.*
        Deleting\sresults\sof\simportant\sjob\s$important_job_id
    /xs, 'cleanup steps in right order';
    is $job->{state}, 'finished', 'job considered successful';
    is $job->{result}, 'Done with results dir after deleting results from important jobs',
      'finished within expected step';
};

subtest 'jobs in archive not considered by default' => sub {
    # setup: as in the previous subtest but this time the important job is flagged as archived and is therefore
    #        not supposed to be considered
    %gained_disk_space_by_deleting_results_of_job = ($important_job_id => 1);
    $jobs->find($important_job_id)->update({archived => 1});

    my $job = job_log_like qr/
        Deleting\svideo\sof\sjob\s$unimportant_job_id.*
        Deleting\sresults\sof\sjob\s$unimportant_job_id.*
        Deleting\svideo\sof\simportant\sjob\s$new_job_id.*
    /xs, 'cleanup steps in right order without archived job mentioned';
    is $job->{state}, 'failed', 'job considered failed';
    is $job->{result}, 'Unable to cleanup enough results from results dir',
      'not finished as job that could gain disk space is in the archive';
};

subtest 'jobs in archive considered via archive_min_free_disk_space_percentage' => sub {
    # setup: as in the previous subtest but this time the job is supposed to be deleted from the archive
    $app->config->{misc_limits}->{archive_min_free_disk_space_percentage} = 31;

    my @expected_messages = (
        'Unable to cleanup enough results from results dir',
        'Done with archive after deleting results from important jobs',
    );

    my $job = job_log_like qr/
        Deleting\svideo\sof\simportant\sjob\s$important_job_id.*
        Deleting\sresults\sof\simportant\sjob\s$important_job_id.*
        Deleting\svideo\sof\sjob\s$unimportant_job_id.*
        Deleting\sresults\sof\sjob\s$unimportant_job_id.*
        Deleting\svideo\sof\simportant\sjob\s$new_job_id.*
    /xs, 'cleanup steps in right order';
    is $job->{state}, 'failed', 'job considered failed';
    is $job->{result}, join("\n", @expected_messages),
      'not finished as job that could gain disk space is in the archive';
};

subtest 'archive cleanup skipped if archive not full; result dir cleanup still attempted' => sub {
    # setup: as in the previous subtest but this time the archive is not full
    $app->config->{misc_limits}->{archive_min_free_disk_space_percentage} = 30;

    my @expected_messages = ('Unable to cleanup enough results from results dir', 'Nothing to do for archive');
    my $job = job_log_like qr/
        Deleting\svideo\sof\sjob\s$unimportant_job_id.*
        Deleting\sresults\sof\sjob\s$unimportant_job_id.*
        Deleting\svideo\sof\simportant\sjob\s$new_job_id.*
    /xs, 'cleanup steps in right order; important and archived job not considered as archive not full';
    is $job->{state}, 'failed', 'job considered failed';
    is $job->{result}, join("\n", @expected_messages),
      'not finished as job that could gain disk space is in the archive';
};

subtest 'deleted screenshots always accounted to main storage' => sub {
    # setup: assume that only the deletion of screenshots has freed the disk space when deleting archived job
    $app->config->{misc_limits}->{archive_min_free_disk_space_percentage} = 31;
    %gained_disk_space_by_deleting_results_of_job = ();
    %gained_disk_space_by_deleting_screenshots_of_job = ($important_job_id => 1);

    my @expected_messages = ('Nothing to do for results dir', 'Unable to cleanup enough results from archive');
    my $job = job_log_like qr/
        Deleting\svideo\sof\simportant\sjob\s$important_job_id.*
        Deleting\sresults\sof\simportant\sjob\s$important_job_id.*
    /xs, 'cleanup steps in right order; important and archived job not considered as archive not full';
    is $job->{state}, 'failed', 'job considered failed';
    is $job->{result}, join("\n", @expected_messages),
      'not finished as job that gained disk space only did so by deleting screenshots on main storage';
};

done_testing();
