#!/usr/bin/env perl
# Copyright 2019-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '20';
use OpenQA::Utils qw(resultdir imagesdir);
use OpenQA::Test::Database;
use OpenQA::Schema::Result::ScreenshotLinks;
use OpenQA::Task::Job::Limit;
use OpenQA::Test::Utils qw(run_gru_job);
use OpenQA::ScreenshotDeletion;
use Mojo::File qw(path tempdir);
use Mojo::Log;
use Test::Output qw(combined_like);
use Test::Mojo;
use Test::Warnings ':report_warnings';
use DateTime;

my $schema = OpenQA::Test::Database->new->create(fixtures_glob => '01-jobs.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');
my $app = $t->app;
my $screenshots = $schema->resultset('Screenshots');
my $screenshot_links = $schema->resultset('ScreenshotLinks');
my $jobs = $schema->resultset('Jobs');

$app->log(Mojo::Log->new(level => 'debug'));

# add two screenshots to a job
combined_like { $screenshots->populate_images_to_job([qw(foo bar)], 99926) }
qr/creating foo.+creating bar/s, 'screenshots created';
my @screenshot_links = $screenshot_links->search({job_id => 99926}, {order_by => 'screenshot_id'})->all;
my @screenshot_ids = map { $_->screenshot_id } @screenshot_links;
my @screenshots = $screenshots->search({id => {-in => \@screenshot_ids}})->search({}, {order_by => 'id'});
my @screenshot_data = map { {filename => $_->filename} } @screenshots;
is(scalar @screenshot_links, 2, '2 screenshot links for job 99926 created');
is_deeply(\@screenshot_data, [{filename => 'foo'}, {filename => 'bar'}], 'two screenshots created')
  or diag explain \@screenshot_data;
my $exclusive_screenshot_ids = $jobs->find(99926)->exclusively_used_screenshot_ids;
is_deeply([sort @$exclusive_screenshot_ids], \@screenshot_ids, 'screenshots are considered exclusively used')
  or diag explain $exclusive_screenshot_ids;

# add one of the screenshots to another job
combined_like { $screenshots->populate_images_to_job([qw(foo)], 99927) }
qr/creating foo/, 'screenshot created';
@screenshot_links = $screenshot_links->search({job_id => 99927})->all;
is(scalar @screenshot_links, 1, 'screenshot link for job 99927 created');
is_deeply(
    $jobs->find(99926)->exclusively_used_screenshot_ids,
    [$screenshots->find({filename => 'bar'})->id],
    'only bar is considered exclusively used by 99926 anymore'
) or diag explain $exclusive_screenshot_ids;

# delete the first job
$jobs->find(99926)->delete;
@screenshot_links = $screenshot_links->search({job_id => 99926})->all;
@screenshots = $screenshots->search({id => {-in => \@screenshot_ids}})->search({}, {order_by => 'id'});
@screenshot_data = map { {filename => $_->filename} } @screenshots;
is($jobs->find(99926), undef, 'job deleted');
is(scalar @screenshot_links, 0, 'screenshot links for job 99926 deleted');
is_deeply(
    \@screenshot_data,
    [{filename => 'foo'}, {filename => 'bar'}],
    'screenshot not directly cleaned up after deleting job'
) or diag explain \@screenshot_data;

# limit screenshots
my %args = (
    min_screenshot_id => $screenshots->search(undef, {rows => 1, order_by => {-asc => 'id'}})->first->id,
    max_screenshot_id => $screenshots->search(undef, {rows => 1, order_by => {-desc => 'id'}})->first->id,
    screenshots_per_batch => OpenQA::Task::Job::Limit::DEFAULT_SCREENSHOTS_PER_BATCH,
);
combined_like { run_gru_job($app, limit_screenshots => \%args) }
qr/Removing screenshot batch 1/, 'removing screenshot logged';
@screenshots = $screenshots->search({id => {-in => \@screenshot_ids}})->search({}, {order_by => 'id'});
@screenshot_data = map { {filename => $_->filename} } @screenshots;
is_deeply(\@screenshot_data, [{filename => 'foo'}], 'foo still present (used in 99927), bar removed (no longer used)')
  or diag explain \@screenshot_data;

subtest 'screenshots are unique' => sub {
    combined_like { $screenshots->populate_images_to_job(['whatever'], 99927) }
    qr/creating whatever/, 'screenshot created';
    combined_like { $screenshots->populate_images_to_job(['whatever'], 99927) }
    qr/creating whatever/, 'screenshot created (duplicate)';
    my @whatever = $screenshots->search({filename => 'whatever'})->all;
    is $whatever[0]->filename, 'whatever', 'right filename';
    is $whatever[1], undef, 'no second result';
};

sub get_enqueued_minion_jobs {
    my ($minion, $job_query_args) = @_;

    my $enqueued_jobs = $minion->jobs($job_query_args);
    my (@enqueued_job_ids, @enqueued_job_args);
    while (my $info = $enqueued_jobs->next) {
        push(@enqueued_job_ids, $info->{id});
        push(@enqueued_job_args, $info->{args});
    }
    @enqueued_job_args = sort { $a->[0]->{min_screenshot_id} <=> $b->[0]->{min_screenshot_id} } @enqueued_job_args;
    return {
        enqueued_job_args => \@enqueued_job_args,
        enqueued_job_ids => \@enqueued_job_ids,
    };
}

subtest 'limiting screenshots split into multiple Minion jobs' => sub {
    subtest 'test setup' => sub {
        # create additional screenshots to get an ID range of [1; 206]
        $screenshots->create({filename => 'test-' . $_, t_created => DateTime->now(time_zone => 'UTC')}) for (0 .. 200);
        my ($min_id, $max_id) = $schema->storage->dbh->selectrow_array('select min(id), max(id) from screenshots');
        is($min_id, 1, 'min ID');
        is($max_id, 206, 'max ID');
    };

    # run a limit_results_and_logs job with customized batch parameters
    run_gru_job($app, limit_results_and_logs => [{screenshots_per_batch => 20, batches_per_minion_job => 5}]);

    # check whether "limit_results_and_logs" enqueues further "limit_screenshots" and "ensure_results_below_threshold"
    # jobs
    my $minion = $app->minion;
    my $enqueued_minion_jobs
      = get_enqueued_minion_jobs($minion, {states => ['inactive'], tasks => ['limit_screenshots']});
    my $enququed_minion_job_ids = $enqueued_minion_jobs->{enqueued_job_ids};
    my $enququed_minion_job_args = $enqueued_minion_jobs->{enqueued_job_args};
    is_deeply(
        $enququed_minion_job_args,
        [
            [{min_screenshot_id => 1, max_screenshot_id => 100, screenshots_per_batch => 20}],
            [{min_screenshot_id => 101, max_screenshot_id => 200, screenshots_per_batch => 20}],
            [{min_screenshot_id => 201, max_screenshot_id => 206, screenshots_per_batch => 20}],
        ],
        'limit_screenshots tasks enqueued'
    ) or diag explain $enququed_minion_job_args;
    $enqueued_minion_jobs
      = get_enqueued_minion_jobs($minion, {states => ['inactive'], tasks => ['ensure_results_below_threshold']});
    is_deeply($enqueued_minion_jobs->{enqueued_job_args}, [], 'ensure_results_below_threshold not enqueued by default')
      or diag explain $enqueued_minion_jobs;

    # perform the job for the 2nd screenshot range first to check whether it really only removes screenshots in
    # the expected range
    my $worker = $minion->worker->register;
    my $args = $enququed_minion_job_args->[1]->[0];
    combined_like { $worker->dequeue(0, {id => $enququed_minion_job_ids->[1]})->perform }
    qr/Removing screenshot batch 1/, 'screenshots being removed';
    is($screenshots->search({id => {-between => [$args->{min_screenshot_id}, $args->{max_screenshot_id}]}})->count,
        0, 'all screenshots in the range deleted');
    is($screenshots->search({filename => {-like => 'test-%'}})->count,
        101, 'screenshots of other ranges not deleted yet');

    # perform remaining enqueued jobs
    combined_like {
        $worker->dequeue(0, {id => $_})->perform for ($enququed_minion_job_ids->[0], $enququed_minion_job_ids->[2])
    }
    qr/Removing screenshot batch 1/, 'screenshots being removed';
    $worker->unregister;

    my @remaining_screenshots = map { $_->filename } $screenshots->search(undef, {order_by => 'filename'});
    is_deeply(\@remaining_screenshots, [qw(foo whatever)], 'all screenshots removed except foo and whatever')
      or diag explain \@remaining_screenshots;

    subtest 'run a limit_results_and_logs job with batch parameters from config' => sub {
        run_gru_job($app, limit_results_and_logs => [{}]);
        my $enqueued_minion_jobs
          = get_enqueued_minion_jobs($minion, {states => ['inactive'], tasks => ['limit_screenshots']});
        my $enququed_minion_job_args = $enqueued_minion_jobs->{enqueued_job_args};
        is_deeply(
            $enququed_minion_job_args,
            [[{min_screenshot_id => 1, max_screenshot_id => 4, screenshots_per_batch => 200000}]],
            'limit_screenshots task with default batch size from config enqueued'
        ) or diag explain $enququed_minion_job_args;
    };

};

subtest 'deleting screenshots of a single job' => sub {
    $ENV{OPENQA_BASEDIR} = my $base_dir = tempdir;
    path(resultdir)->make_path;

    my @fake_screenshots = (qw(a-screenshot another-screenshot foo));
    my $imagesdir = path(imagesdir);
    my $thumsdir = path($imagesdir, '.thumbs');
    my $job = $jobs->create({TEST => 'delete-results', logs_present => 1, result_size => 1000});
    $job->discard_changes;
    combined_like { $screenshots->populate_images_to_job(\@fake_screenshots, $job->id) }
    qr/creating.*a-screenshot.*another-screenshot.*foo/s, 'screenshots populated';
    $thumsdir->make_path;
    for my $screenshot (@fake_screenshots) {
        path($imagesdir, $screenshot)->spurt('--');
        path($thumsdir, $screenshot)->spurt('---');
    }

    ok -d (my $result_dir = path($job->create_result_dir)), 'result directory created';
    $result_dir->child('foo')->spurt('-----');
    is $job->delete_results, 2 * (2 + 3) + 5, 'size of deleted results returned';
    $job->discard_changes;
    is $job->logs_present, 0, 'logs not considered present anymore';
    is $job->result_size, 0, 'result size cleared';
    ok !-e $result_dir, 'result dir deleted';
    is_deeply [map { $_->filename } $screenshots->search({filename => {-in => \@fake_screenshots}})->all], ['foo'],
      'all screenshots deleted, except "foo" which is still used by another job';
    ok -e path($imagesdir, 'foo'), 'shared screenshot foo still present';
    ok -e path($thumsdir, 'foo'), 'shared screenshot thumbnail foo still present';
    for my $screenshot (qw(a-screenshot another-screenshot)) {
        ok !-e path($imagesdir, $screenshot), "exclusive screenshot $screenshot deleted";
        ok !-e path($thumsdir, $screenshot), "exclusive screenshot thumbnail $screenshot deleted";
    }
};

subtest 'unable to delete screenshot' => sub {
    # create a new screenshot and simply put a directory in its place (dirs can not be deleted via unlink)
    my $tempdir = tempdir;
    my $subdir = $tempdir->child('not-deletable');
    my $deleted_size = 100;
    my $screenshot_deletion = OpenQA::ScreenshotDeletion->new(
        dbh => $schema->storage->dbh,
        imagesdir => $tempdir,
        deleted_size => \$deleted_size
    );
    my $screenshot = $screenshots->create({filename => 'not-deletable/screenshot', t_created => '2021-01-26 08:06:54'});
    $screenshot->discard_changes;
    $subdir->make_path;
    $subdir->child($_)->make_path for (qw(screenshot .thumbs/screenshot));
    combined_like { $screenshot_deletion->delete_screenshot($screenshot->id, $screenshot->filename) }
    qr{Can't remove screenshot .*not-deletable/screenshot.*Can't remove thumbnail .*not-deletable/.thumbs/screenshot}s,
      'errors logged';
    is $deleted_size, 100, 'deleted size not incremented';

    # cover case when only the screenshot or when only the thumbnail can be deleted
    my $only_screenshot = $screenshots->create({filename => 'only-screenshot', t_created => '2021-01-26 08:06:54'});
    my $only_thumb = $screenshots->create({filename => 'only-thumb', t_created => '2021-01-26 08:06:54'});
    $only_screenshot->discard_changes;
    $only_thumb->discard_changes;
    $tempdir->child('only-screenshot')->spurt('---');
    $tempdir->child('.thumbs')->make_path->child('only-thumb')->spurt('-----');
    $screenshot_deletion->delete_screenshot($only_screenshot->id, $only_screenshot->filename);
    is $deleted_size, 103, 'size of screenshot tracked';
    $screenshot_deletion->delete_screenshot($only_screenshot->id, $only_thumb->filename);
    is $deleted_size, 108, 'size of thumbnail tracked';
};

subtest 'no errors in database log' => sub {
    my $prep = $schema->storage->dbh->prepare('select pg_current_logfile()');
    $prep->execute;
    my $db_log_file = path($ENV{TEST_PG} =~ s/^.*host=//r, $prep->fetchrow_arrayref->[0]);
    my $log = Mojo::File->new($db_log_file)->slurp;
    unlike $log, qr/duplicate.*violates unique constraint "screenshots_filename"/, 'no unique constraint error';
};

done_testing();
