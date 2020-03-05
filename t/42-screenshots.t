#!/usr/bin/env perl
# Copyright (C) 2019-2020 SUSE LLC
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

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";
use OpenQA::Utils;
use OpenQA::Test::Database;
use OpenQA::Schema::Result::ScreenshotLinks;
use OpenQA::Task::Job::Limit;
use OpenQA::Test::Utils qw(run_gru_job collect_coverage_of_gru_jobs);
use Mojo::File 'path';
use Mojo::Log;
use Test::Output 'combined_like';
use Test::More;
use Test::MockModule;
use Test::Mojo;
use Test::Warnings;
use DateTime;

my $schema           = OpenQA::Test::Database->new->create;
my $t                = Test::Mojo->new('OpenQA::WebAPI');
my $app              = $t->app;
my $screenshots      = $schema->resultset('Screenshots');
my $screenshot_links = $schema->resultset('ScreenshotLinks');
my $jobs             = $schema->resultset('Jobs');

$app->log(Mojo::Log->new(level => 'debug'));
collect_coverage_of_gru_jobs($app);

# add two screenshots to a job
$app->schema->resultset('Screenshots')->populate_images_to_job([qw(foo bar)], 99926);
my @screenshot_links = $screenshot_links->search({job_id => 99926})->all;
my @screenshot_ids   = map { $_->screenshot_id } @screenshot_links;
my @screenshots      = $screenshots->search({id => {-in => \@screenshot_ids}})->search({}, {order_by => 'id'});
my @screenshot_data  = map { {filename => $_->filename} } @screenshots;
is(scalar @screenshot_links, 2, '2 screenshot links for job 99926 created');
is_deeply(\@screenshot_data, [{filename => 'foo'}, {filename => 'bar'}], 'two screenshots created')
  or diag explain \@screenshot_data;

# add one of the screenshots to another job
$app->schema->resultset('Screenshots')->populate_images_to_job([qw(foo)], 99927);
@screenshot_links = $screenshot_links->search({job_id => 99927})->all;
is(scalar @screenshot_links, 1, 'screenshot link for job 99927 created');

# delete the first job
$jobs->find(99926)->delete;
@screenshot_links = $screenshot_links->search({job_id => 99926})->all;
@screenshots      = $screenshots->search({id => {-in => \@screenshot_ids}})->search({}, {order_by => 'id'});
@screenshot_data  = map { {filename => $_->filename} } @screenshots;
is($jobs->find(99926),       undef, 'job deleted');
is(scalar @screenshot_links, 0,     'screenshot links for job 99926 deleted');
is_deeply(
    \@screenshot_data,
    [{filename => 'foo'}, {filename => 'bar'}],
    'screenshot not directly cleaned up after deleting job'
) or diag explain \@screenshot_data;

# limit screenshots
my %args = (
    min_screenshot_id     => $screenshots->search(undef, {rows => 1, order_by => {-asc  => 'id'}})->first->id,
    max_screenshot_id     => $screenshots->search(undef, {rows => 1, order_by => {-desc => 'id'}})->first->id,
    screenshots_per_batch => OpenQA::Task::Job::Limit::SCREENSHOTS_PER_BATCH,
);
combined_like(
    sub { run_gru_job($app, limit_screenshots => \%args); },
    qr/removing screenshot bar/,
    'removing screenshot logged'
);
@screenshots     = $screenshots->search({id => {-in => \@screenshot_ids}})->search({}, {order_by => 'id'});
@screenshot_data = map { {filename => $_->filename} } @screenshots;
is_deeply(\@screenshot_data, [{filename => 'foo'}], 'foo still present (used in 99927), bar removed (no longer used)')
  or diag explain \@screenshot_data;

subtest 'screenshots are unique' => sub {
    my $screenshots = $app->schema->resultset('Screenshots');
    $screenshots->populate_images_to_job(['whatever'], 99927);
    $screenshots->populate_images_to_job(['whatever'], 99927);
    my @whatever = $screenshots->search({filename => 'whatever'})->all;
    is $whatever[0]->filename, 'whatever', 'right filename';
    is $whatever[1], undef, 'no second result';
};

subtest 'limiting screenshots splitted into multiple Minion jobs' => sub {
    subtest 'test setup' => sub {
        # create additional screenshots to get an ID range of [1; 206]
        $screenshots->create({filename => 'test-' . $_, t_created => DateTime->now(time_zone => 'UTC')}) for (0 .. 200);
        my ($min_id, $max_id) = $schema->storage->dbh->selectrow_array('select min(id), max(id) from screenshots');
        is($min_id, 1,   'min ID');
        is($max_id, 206, 'max ID');
    };

    # run a limit_results_and_logs job with customized batch parameters
    run_gru_job($app, limit_results_and_logs => [{screenshots_per_batch => 20, batches_per_minion_job => 5}]);

    # check whether "limit_results_and_logs" enqueues further "limit_screenshots" jobs
    my $minion        = $app->minion;
    my $enqueued_jobs = $minion->jobs({states => ['inactive'], tasks => ['limit_screenshots']});
    my (@enqueued_job_ids, @enqueued_job_args);
    while (my $info = $enqueued_jobs->next) {
        push(@enqueued_job_ids,  $info->{id});
        push(@enqueued_job_args, $info->{args});
    }
    @enqueued_job_args = sort { $a->[0]->{min_screenshot_id} <=> $b->[0]->{min_screenshot_id} } @enqueued_job_args;
    is_deeply(
        \@enqueued_job_args,
        [
            [{min_screenshot_id => 1,   max_screenshot_id => 100, screenshots_per_batch => 20}],
            [{min_screenshot_id => 101, max_screenshot_id => 200, screenshots_per_batch => 20}],
            [{min_screenshot_id => 201, max_screenshot_id => 206, screenshots_per_batch => 20}],
        ],
        'limit_screenshots tasks enqueued'
    ) or diag explain \@enqueued_job_args;

    # perform the job for the 2nd screenshot range first to check whether it really only removes screenshots in
    # the expected range
    my $worker = $minion->worker->register;
    my $args   = $enqueued_job_args[1]->[0];
    combined_like(
        sub { $worker->dequeue(0, {id => $enqueued_job_ids[1]})->perform },
        qr/removing screenshot/,
        'screenshots being removed'
    );
    is($screenshots->search({id => {-between => [$args->{min_screenshot_id}, $args->{max_screenshot_id}]}})->count,
        0, 'all screenshots in the range deleted');
    is($screenshots->search({filename => {-like => 'test-%'}})->count,
        101, 'screenshots of other ranges not deleted yet');

    # perform remaining enqueued jobs
    combined_like(
        sub { $worker->dequeue(0, {id => $_})->perform for ($enqueued_job_ids[0], $enqueued_job_ids[2]) },
        qr/removing screenshot/,
        'screenshots being removed'
    );
    $worker->unregister;

    my @remaining_screenshots = map { $_->filename } $screenshots->search(undef, {order_by => 'filename'});
    is_deeply(\@remaining_screenshots, [qw(foo whatever)], 'all screenshots removed except foo and whatever')
      or diag explain \@remaining_screenshots;
};

subtest 'no errors in database log' => sub {
    my $prep = $schema->storage->dbh->prepare('select pg_current_logfile()');
    $prep->execute;
    my $db_log_file = path($ENV{TEST_PG} =~ s/^.*host=//r, $prep->fetchrow_arrayref->[0]);
    my $log         = Mojo::File->new($db_log_file)->slurp;
    unlike $log, qr/duplicate.*violates unique constraint "screenshots_filename"/, 'no unique constraint error';
};

done_testing();
