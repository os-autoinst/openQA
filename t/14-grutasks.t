#!/usr/bin/env perl
# Copyright (c) 2016-2020 SUSE LLC
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
use OpenQA::Utils;
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use File::Copy;
use OpenQA::Test::Database;
use OpenQA::Test::Utils qw(run_gru_job);
use Test::MockModule;
use Test::Mojo;
use Test::Warnings ':report_warnings';
use Test::Output 'combined_like';
use OpenQA::Test::Case;
use File::Which 'which';
use File::Path ();
use Data::Dumper 'Dumper';
use Date::Format 'time2str';
use Fcntl ':mode';
use Mojo::File qw(path tempdir);
use Mojo::Log;
use Storable qw(store retrieve);
use Mojo::IOLoop;
use utf8;

my $nr_minion_jobs_ttl_test = $ENV{OPENQA_NR_MINION_JOBS_TTL_TEST} // 100;

# mock asset deletion
# * prevent removing assets from database and file system
# * keep track of calls to OpenQA::Schema::Result::Assets::delete and OpenQA::Schema::Result::Assets::remove_from_disk
my $tempdir = tempdir;
my $deleted = $tempdir->child('deleted');
my $removed = $tempdir->child('removed');
sub mock_deleted { -e $deleted ? retrieve($deleted) : [] }
sub mock_removed { -e $removed ? retrieve($removed) : [] }
sub reset_mocked_asset_deletions { unlink $tempdir->child($_) for qw(removed deleted) }
my $assets_result_mock = Test::MockModule->new('OpenQA::Schema::Result::Assets');
$assets_result_mock->redefine(
    delete => sub {
        my ($self) = @_;
        $self->remove_from_disk;
        store([], $deleted) unless -e $deleted;
        my $array = retrieve($deleted);
        push @$array, $self->name;
        store($array, $deleted);
    });
$assets_result_mock->redefine(
    remove_from_disk => sub {
        my ($self) = @_;
        store([], $removed) unless -e $removed;
        my $array = retrieve($removed);
        push @$array, $self->name;
        store($array, $removed);
    });
$assets_result_mock->redefine(refresh_size => sub { });

# setup test config and database
my $test_case     = OpenQA::Test::Case->new(config_directory => "$FindBin::Bin/data/41-audit-log");
my $schema        = $test_case->init_data(fixtures_glob => '01-jobs.pl 04-products.pl');
my $jobs          = $schema->resultset('Jobs');
my $job_groups    = $schema->resultset('JobGroups');
my $parent_groups = $schema->resultset('JobGroupParents');
my $assets        = $schema->resultset('Assets');
my $job_assets    = $schema->resultset('JobsAssets');

# move group 1002 into a parent group
# note: This shouldn't change much because 1002 will be the only child and the same limit applies.
#       However, the size of exclusively kept assets is moved to the parent-level.
$parent_groups->create({id => 1, name => 'parent of "opensuse test"', size_limit_gb => 100});
$job_groups->search({id => 1002})->update({parent_id => 1});

# refresh assets only once and prevent adding untracked assets
my $assets_mock = Test::MockModule->new('OpenQA::Schema::ResultSet::Assets');
$schema->resultset('Assets')->refresh_assets();
$assets_mock->redefine(scan_for_untracked_assets => sub { });
$assets_mock->redefine(refresh_assets            => sub { });

my $t = Test::Mojo->new('OpenQA::WebAPI');

# launch an additional app to serve some file for testing blocking downloads
my $mojo_port = Mojo::IOLoop::Server->generate_port;
my $webapi    = OpenQA::Test::Utils::create_webapi($mojo_port, sub { });

# define a fix asset_size_limit configuration for this test to be independent of the default value
# we possibly want to adjust without going into the details of this test
$t->app->config->{default_group_limits}->{asset_size_limit} = 100;

# Allow Devel::Cover to collect stats for background jobs
sub cover { Devel::Cover::report() if Devel::Cover->can('report') }
$t->app->minion->on(
    worker => sub {
        my ($minion, $worker) = @_;
        $worker->on(
            dequeue => sub {
                my ($worker, $job) = @_;
                $job->on(cleanup => \&cover) unless $job->info->{notes}{no_cover};
            });
    });

# Non-Gru task
$t->app->minion->add_task(
    some_random_task => sub {
        my ($job, @args) = @_;
        $job->finish({pid => $$, args => \@args});
    });

# Gru retry task
$t->app->minion->add_task(
    gru_retry_task => sub {
        my ($job, @args) = @_;
        return $job->retry({delay => 30})
          unless my $guard = $job->minion->guard('limit_gru_retry_task', 3600);
    });

# Gru task that reached failed/finished manually
$t->app->minion->add_task(
    gru_manual_task => sub {
        my ($job, $todo) = @_;
        if ($todo eq 'fail') {
            $job->fail('Manual fail');
        }
        elsif ($todo eq 'finish') {
            $job->finish('Manual finish');
        }
        elsif ($todo eq 'die') {
            warn 'About to throw';
            die 'Thrown fail';
        }
    });

# list initially existing assets
my $dbh             = $schema->storage->dbh;
my $initial_aessets = $dbh->selectall_arrayref('select * from assets order by id;');
note('initially existing assets:');
note(Dumper($initial_aessets));

sub find_kept_assets_with_last_jobs {
    my $last_used_jobs = $assets->search(
        {
            -not => {
                -or => {
                    name            => {-in => mock_removed()},
                    last_use_job_id => undef
                },
            }
        },
        {
            order_by => {-asc => 'last_use_job_id'}});
    return [map { {asset => $_->name, job => $_->last_use_job_id} } $last_used_jobs->all];
}
is_deeply(find_kept_assets_with_last_jobs, [], 'initially, none of the assets has the job of its last use assigned');
is($job_groups->find(1001)->exclusively_kept_asset_size,
    undef, 'initially no size for exclusively kept assets accumulated');

# understanding / revising these tests requires understanding the
# assets in the test database. As I write this, there are 6 assets
# in the Assets schema. assets 1, 2, 3, 4 and 5 are in job group 1001.
# assets 2 and 6 are in job group 1002. asset 5 is fixed, meaning
# limit_assets will see it but ignore it quite early on: it will
# never be deleted, nor will it ever be explicitly 'kept' and seen
# by the find_kept_assets_with_last_jobs query above (as it won't
# have a last_use_job_id).
#
# So essentially on each run through of limit_assets, it will first
# run through group 1001 and consider assets 3, 2, 1 and 4 in that
# order (as the most recent job associated with 4 is older than the
# most recent job associated with 1, and so on). Then it will run
# through group 1002 and consider assets 2 and 6 in that order. If
# group 1001 selects 2 for deletion, 1002 may cause it to be 'kept',
# but that is the only likely interaction between the groups.
#
# asset 2 is also associated with a running job, so even if it is
# scheduled for deletion after both groups 1001 and 1002 are checked,
# it should never actually get deleted.
#
# For this test we update the size of all assets to be 18 GiB
# so both groups should be under the size limit, and no deletion
# should occur.
my $gib = 1024 * 1024 * 1024;
$assets->update({size => 18 * $gib});
run_gru_job($t->app, 'limit_assets');

is_deeply(mock_removed(), [], "nothing should have been 'removed' at size 18GiB");
is_deeply(mock_deleted(), [], "nothing should have been 'deleted' at size 18GiB");

my @expected_last_jobs_no_removal = (
    {asset => 'openSUSE-Factory-staging_e-x86_64-Build87.5011-Media.iso', job => 99926},
    {asset => 'openSUSE-13.1-x86_64.hda',                                 job => 99946},
    {asset => 'openSUSE-13.1-DVD-i586-Build0091-Media.iso',               job => 99947},
    {asset => 'testrepo',                                                 job => 99961},
    {asset => 'openSUSE-13.1-DVD-x86_64-Build0091-Media.iso',             job => 99963},
    {asset => 'openSUSE-13.1-GNOME-Live-i686-Build0091-Media.iso',        job => 99981},
);

is_deeply(find_kept_assets_with_last_jobs, \@expected_last_jobs_no_removal, 'last jobs correctly assigned');

# job group 1001 should exclusively keep 3, 1, 5 and 4
is($job_groups->find(1001)->exclusively_kept_asset_size,
    72 * $gib, 'kept assets for group 1001 accumulated (18 GiB per asset)');
# parent group 1 should exclusively keep 2 and 6 belonging to its job group 1002
is($parent_groups->find(1)->exclusively_kept_asset_size,
    36 * $gib, 'kept assets for group 1 accumulated (18 GiB per asset)');
# 1002 should exclusively keep 2 and 6
is($job_groups->find(1002)->exclusively_kept_asset_size,
    0, 'nothing accumulated for individual job group within parent');


# at size 24GiB, group 1001 is over the 80% threshold but under the 100GiB
# limit - still no removal should occur.
$assets->update({size => 24 * $gib});
run_gru_job($t->app, 'limit_assets');

is_deeply(mock_removed(), [], "nothing should have been 'removed' at size 24GiB");
is_deeply(mock_deleted(), [], "nothing should have been 'deleted' at size 24GiB");

is_deeply(find_kept_assets_with_last_jobs, \@expected_last_jobs_no_removal, 'last jobs have not been altered');

# job group 1001 should exclusively keep the same as above
is(
    $job_groups->find(1001)->exclusively_kept_asset_size,
    4 * 24 * $gib,
    'kept assets for group 1001 accumulated, job over threshold not taken into account (24 GiB per asset)'
);
# parent group 1 should exclusively keep the same as above
is(
    $parent_groups->find(1)->exclusively_kept_asset_size,
    2 * 24 * $gib,
    'kept assets for group 1002 accumulated (24 GiB per asset)'
);

# at size 26GiB, 1001 is over the limit, so removal should occur. Removing
# just one asset - #4 - will get under the 80GiB threshold.
$assets->update({size => 26 * $gib});
run_gru_job($t->app, 'limit_assets');

is(scalar @{mock_removed()}, 1, "one asset should have been 'removed' at size 26GiB");
is(scalar @{mock_deleted()}, 1, "one asset should have been 'deleted' at size 26GiB");

is_deeply(
    find_kept_assets_with_last_jobs,
    [
        {asset => 'openSUSE-13.1-x86_64.hda',                          job => 99946},
        {asset => 'openSUSE-13.1-DVD-i586-Build0091-Media.iso',        job => 99947},
        {asset => 'testrepo',                                          job => 99961},
        {asset => 'openSUSE-13.1-DVD-x86_64-Build0091-Media.iso',      job => 99963},
        {asset => 'openSUSE-13.1-GNOME-Live-i686-Build0091-Media.iso', job => 99981}
    ],
    'last jobs still present but first one deleted'
);

# job group 1001 should exclusively keep 3, 5 and 1
is(
    $job_groups->find(1001)->exclusively_kept_asset_size,
    3 * 26 * $gib,
    'kept assets for group 1001 accumulated and deleted asset not taken into account (26 GiB per asset)'
);
# parent group 1 should exclusively keep 2 and 6 belonging to its job group 1002
is(
    $parent_groups->find(1)->exclusively_kept_asset_size,
    2 * 26 * $gib,
    'kept assets for group 1002 accumulated (26 GiB per asset)'
);

reset_mocked_asset_deletions;

# at size 34GiB, 1001 is over the limit, so removal should occur.
$assets->update({size => 34 * $gib});
run_gru_job($t->app, 'limit_assets');

is(scalar @{mock_removed()}, 1, "two assets should have been 'removed' at size 34GiB");
is(scalar @{mock_deleted()}, 1, "two assets should have been 'deleted' at size 34GiB");

is_deeply(
    find_kept_assets_with_last_jobs,
    [
        {asset => 'openSUSE-13.1-x86_64.hda',                          job => 99946},
        {asset => 'openSUSE-13.1-DVD-i586-Build0091-Media.iso',        job => 99947},
        {asset => 'testrepo',                                          job => 99961},
        {asset => 'openSUSE-13.1-DVD-x86_64-Build0091-Media.iso',      job => 99963},
        {asset => 'openSUSE-13.1-GNOME-Live-i686-Build0091-Media.iso', job => 99981}
    ],
    'last jobs still present but first two deleted'
);

# 1001 should exclusively keep 1, 3 and 5
is(
    $job_groups->find(1001)->exclusively_kept_asset_size,
    2 * 34 * $gib,
    'kept assets for group 1001 accumulated and deleted asset not taken into account (34 GiB per asset)'
);
# parent group 1 should exclusively keep 2 and 6 belonging to its job group 1002
is(
    $parent_groups->find(1)->exclusively_kept_asset_size,
    2 * 34 * $gib,
    'kept assets for group 1002 accumulated (34 GiB per asset)'
);

reset_mocked_asset_deletions;

subtest 'assets associated with pending jobs are preserved' => sub {
    # set the most recent job for asset 1 (which is supposed to be 99947) to PENDING to test protection of
    # assets for PENDING jobs which would otherwise be removed
    my $pending_asset               = $assets->find(1);
    my $pending_asset_name          = $pending_asset->name;
    my $other_asset_name            = 'openSUSE-Factory-staging_e-x86_64-Build87.5011-Media.iso';
    my $most_reject_job_for_asset_1 = $job_assets->find({asset_id => 1}, {order_by => {-desc => 'job_id'}, rows => 1});
    $most_reject_job_for_asset_1 = $most_reject_job_for_asset_1->job if $most_reject_job_for_asset_1;
    is($most_reject_job_for_asset_1->id,
        99947, "job 99947 is actually the most recent job of asset $pending_asset_name");
    my $pending_job = $jobs->find(99947);
    $pending_job->update({state => RUNNING, result => NONE, t_finished => undef});

    # ensure that the asset will actually be removed
    # note: The big size is not completely arbitrarily chosen. It must be bigger than the size of the relevant
    #       group (which is group 1001) so it would *never* survive the cleanup regardless of the order the assets
    #       are considered.
    $pending_asset->update({size => 2e11, fixed => 0});

    subtest 'pending asset preserved' => sub {
        run_gru_job($t->app, 'limit_assets');
        my ($removed_assets, $deleted_assets) = (mock_removed, mock_deleted);
        is_deeply($removed_assets, [$other_asset_name],
            "only other asset $other_asset_name has been removed with 99947 pending")
          or diag explain $removed_assets;
        is_deeply($deleted_assets, [$other_asset_name],
            "only other asset $other_asset_name has been deleted with 99947 pending")
          or diag explain $deleted_assets;
    };

    reset_mocked_asset_deletions;

    subtest 'pending asset preserved even though the most recent job associated with the asset is not pending' => sub {
        # add another job associated with the asset which is *not* pending
        my $another_associated_job
          = $jobs->create({id => 199947, TEST => 'job-with-asset-1', state => DONE, result => PASSED});
        $job_assets->create({asset_id => 1, job_id => $another_associated_job->id});

        run_gru_job($t->app, 'limit_assets');
        my ($removed_assets, $deleted_assets) = (mock_removed, mock_deleted);
        is_deeply($removed_assets, [$other_asset_name],
            "only other asset $other_asset_name has been removed with 99947 pending")
          or diag explain $removed_assets;
        is_deeply($deleted_assets, [$other_asset_name],
            "only other asset $other_asset_name has been deleted with 99947 pending")
          or diag explain $deleted_assets;
        $another_associated_job->discard_changes;
        $another_associated_job->delete;
    };

    reset_mocked_asset_deletions;

    subtest 'asset will be removed when the job is no longer pending' => sub {
        $pending_job->update({state => DONE, result => PASSED});
        run_gru_job($t->app, 'limit_assets');
        my ($removed_assets, $deleted_assets) = (mock_removed, mock_deleted);
        is_deeply(
            [sort @$removed_assets],
            [$pending_asset_name, $other_asset_name],
            "asset $pending_asset_name has been removed with 99947 no longer pending"
        ) or diag explain $removed_assets;
        is_deeply(
            [sort @$deleted_assets],
            [$pending_asset_name, $other_asset_name],
            "asset $pending_asset_name has been deleted with 99947 no longer pending"
        ) or diag explain $deleted_assets;
    # note: The main purpose of this subtest is to cross-check whether this test is actually working. If the asset would
    #       still not be cleaned up here that would mean the pending state makes no difference for this test and it is
    #       therefore meaningless.
    };
};

sub create_temp_job_log_file {
    my ($resultdir) = @_;

    my $filename = $resultdir . '/autoinst-log.txt';
    open(my $fh, ">>", $filename) or die "touch $filename: $!\n";
    close $fh;
    die 'temporary file could not be created' unless -e $filename;
    return $filename;
}

subtest 'limit_results_and_logs gru task cleans up logs' => sub {
    my $job = $t->app->schema->resultset('Jobs')->find(99937);
    $job->update({t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 3600 * 24 * 12, 'UTC')});
    $job->group->update({"keep_logs_in_days" => 5});
    my $filename = create_temp_job_log_file($job->result_dir);
    run_gru_job($t->app, 'limit_results_and_logs');
    ok(!-e $filename, 'file got cleaned');
};

subtest 'limit audit events' => sub {
    my $app            = $t->app;
    my $audit_events   = $app->schema->resultset('AuditEvents');
    my $startup_events = $audit_events->search({event => 'startup'});
    is($startup_events->count, 2, 'two startup events present');

    $startup_events->first->update({t_created => '2019-01-01'});
    run_gru_job($t->app, 'limit_audit_events');
    is($audit_events->search({event => 'startup'})->count, 1, 'old startup event deleted');
};

subtest 'human readable size' => sub {
    is(human_readable_size(0),           '0 Byte',  'zero');
    is(human_readable_size(1),           '1 Byte',  'one');
    is(human_readable_size(13443399680), '13GiB',   'two digits GB');
    is(human_readable_size(8007188480),  '7.5GiB',  'smaller GB');
    is(human_readable_size(-8007188480), '-7.5GiB', 'negative smaller GB');
    is(human_readable_size(717946880),   '685MiB',  'large MB');
    is(human_readable_size(245760),      '240KiB',  'less than a MB');
};

subtest 'labeled jobs considered important' => sub {
    my $job = $t->app->schema->resultset('Jobs')->find(99938);
    # but gets cleaned after important limit - change finished to 12 days ago
    $job->update({t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 3600 * 24 * 12, 'UTC')});
    $job->group->update({"keep_logs_in_days"           => 5});
    $job->group->update({"keep_important_logs_in_days" => 20});
    my $filename = create_temp_job_log_file($job->result_dir);
    my $user     = $t->app->schema->resultset('Users')->find({username => 'system'});
    $job->comments->create({text => 'label:linked from test.domain', user_id => $user->id});
    run_gru_job($t->app, 'limit_results_and_logs');
    ok(-e $filename, 'file did not get cleaned');
    # but gets cleaned after important limit - change finished to 22 days ago
    $job->update({t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 3600 * 24 * 22, 'UTC')});
    run_gru_job($t->app, 'limit_results_and_logs');
    ok(!-e $filename, 'file got cleaned');
};

subtest 'Non-Gru task' => sub {
    my $id = $t->app->minion->enqueue(some_random_task => [23]);
    ok defined $id, 'Job enqueued';
    $t->app->minion->perform_jobs;
    is $t->app->minion->job($id)->info->{state}, 'finished', 'job is finished';
    isnt $t->app->minion->job($id)->info->{result}{pid}, $$, 'job was processed in a different process';
    is_deeply $t->app->minion->job($id)->info->{result}{args}, [23], 'arguments have been passed along';

    my $id2 = $t->app->minion->enqueue(some_random_task => [24, 25]);
    my $id3 = $t->app->minion->enqueue(some_random_task => [26]);
    ok defined $id2, 'Job enqueued';
    ok defined $id3, 'Job enqueued';
    $t->app->minion->perform_jobs;
    is $t->app->minion->job($id2)->info->{state}, 'finished', 'job is finished';
    is $t->app->minion->job($id3)->info->{state}, 'finished', 'job is finished';
    isnt $t->app->minion->job($id2)->info->{result}{pid}, $$, 'job was processed in a different process';
    isnt $t->app->minion->job($id3)->info->{result}{pid}, $$, 'job was processed in a different process';
    is_deeply $t->app->minion->job($id2)->info->{result}{args}, [24, 25], 'arguments have been passed along';
    is_deeply $t->app->minion->job($id3)->info->{result}{args}, [26], 'arguments have been passed along';
};

subtest 'Gru tasks limit' => sub {
    my $id  = $t->app->gru->enqueue(limit_assets => [] => {priority => 10, limit => 1});
    my $res = $t->app->gru->enqueue(limit_assets => [] => {priority => 10, limit => 1});
    ok defined $id, 'First task is scheduled';
    is $res, undef, 'No new job scheduled';
    $id = $t->app->gru->enqueue(limit_assets => [] => {priority => 10, limit => 2});
    ok defined $id, 'Second task is scheduled';
    $res = $t->app->gru->enqueue(limit_assets => [] => {priority => 10, limit => 2});
    is $res, undef, 'Second task is not scheduled anymore';

    is $t->app->minion->backend->list_jobs(0, undef, {tasks => ['limit_assets'], states => ['inactive']})->{total}, 2;

    $t->app->minion->perform_jobs;
    $id = $t->app->gru->enqueue(limit_assets => [] => {priority => 10, limit => 2});
    ok defined $id, 'task is scheduled';
    $id = $t->app->gru->enqueue(limit_assets => [] => {priority => 10, limit => 2});
    ok defined $id, 'task is scheduled';
    $res = $t->app->gru->enqueue(limit_assets => [] => {priority => 10, limit => 2});
    is $res, undef, 'Other tasks is not scheduled anymore';
    $t->app->minion->perform_jobs;
};

subtest 'Gru tasks TTL' => sub {
    $t->app->minion->reset;
    my $job_id = $t->app->gru->enqueue(limit_assets => [] => {priority => 10, ttl => -20})->{minion_id};
    $t->app->minion->perform_jobs;
    my $result = $t->app->minion->job($job_id)->info->{result};
    is ref $result, 'HASH', 'We have a result' or diag explain $result;
    is $result->{error}, 'TTL Expired', 'TTL Expired - job discarded' or diag explain $result;

    $job_id = $t->app->gru->enqueue(limit_assets => [] => {priority => 10, ttl => 20})->{minion_id};
    $t->app->minion->perform_jobs;
    $result = $t->app->minion->job($job_id)->info->{result};

    is ref $result, '', 'Result is the output';
    # Depending on logging options, gru task output can differ
    like $result, qr/Removing asset|Job successfully executed/i, 'TTL not Expired - Job executed'
      or diag explain $result;

    my @ids;
    # use one minion for test coverage collection but the rest without for
    # performance reasons
    my %data = (priority => 10, ttl => -50);
    push @ids, $t->app->gru->enqueue(limit_assets => [] => \%data)->{minion_id};
    my %data_no_cover = (%data, notes => {no_cover => 1});
    for (2 .. $nr_minion_jobs_ttl_test) {
        push @ids, $t->app->gru->enqueue(limit_assets => [] => \%data_no_cover)->{minion_id};
    }
    $t->app->minion->perform_jobs;

    is $t->app->minion->job($_)->info->{result}->{error}, 'TTL Expired', 'TTL Expired - job discarded' for @ids;

    $result = $t->app->gru->enqueue_limit_assets;
    ok exists $result->{minion_id};
    ok exists $result->{gru_id};
    isnt $result->{gru_id}, $result->{minion_id};
    # clear the task queue: otherwise, if the next test is skipped due
    # to OBS_RUN, limit_assets may run in a later test and wipe stuff
    $t->app->minion->reset;
};

subtest 'Gru tasks retry' => sub {
    my $ids   = $t->app->gru->enqueue('gru_retry_task');
    my $guard = $t->app->minion->guard('limit_gru_retry_task', 3600);
    ok $schema->resultset('GruTasks')->find($ids->{gru_id}), 'gru task exists';
    is $t->app->minion->job($ids->{minion_id})->info->{state}, 'inactive', 'minion job is inactive';
    $t->app->minion->perform_jobs;

    ok $schema->resultset('GruTasks')->find($ids->{gru_id}), 'gru task still exists';
    is $t->app->minion->job($ids->{minion_id})->info->{state}, 'inactive', 'minion job is still inactive';
    $t->app->minion->job($ids->{minion_id})->retry({delay => 0});
    undef $guard;
    $t->app->minion->perform_jobs;

    ok !$schema->resultset('GruTasks')->find($ids->{gru_id}), 'gru task no longer exists';
    is $t->app->minion->job($ids->{minion_id})->info->{state}, 'finished', 'minion job is finished';
};

subtest 'Gru manual task' => sub {
    my $ids = $t->app->gru->enqueue('gru_manual_task', ['fail']);
    ok $schema->resultset('GruTasks')->find($ids->{gru_id}), 'gru task exists';
    is $t->app->minion->job($ids->{minion_id})->info->{state}, 'inactive', 'minion job is inactive';
    $t->app->minion->perform_jobs;
    ok !$schema->resultset('GruTasks')->find($ids->{gru_id}), 'gru task no longer exists';
    is $t->app->minion->job($ids->{minion_id})->info->{state},  'failed',      'minion job is failed';
    is $t->app->minion->job($ids->{minion_id})->info->{result}, 'Manual fail', 'minion job has the right result';

    $ids = $t->app->gru->enqueue('gru_manual_task', ['finish']);
    ok $schema->resultset('GruTasks')->find($ids->{gru_id}), 'gru task exists';
    is $t->app->minion->job($ids->{minion_id})->info->{state}, 'inactive', 'minion job is inactive';
    $t->app->minion->perform_jobs;
    ok !$schema->resultset('GruTasks')->find($ids->{gru_id}), 'gru task no longer exists';
    is $t->app->minion->job($ids->{minion_id})->info->{state},  'finished',      'minion job is finished';
    is $t->app->minion->job($ids->{minion_id})->info->{result}, 'Manual finish', 'minion job has the right result';

    $ids = $t->app->gru->enqueue('gru_manual_task', ['die']);
    ok $schema->resultset('GruTasks')->find($ids->{gru_id}), 'gru task exists';
    is $t->app->minion->job($ids->{minion_id})->info->{state}, 'inactive', 'minion job is inactive';
    combined_like { $t->app->minion->perform_jobs } qr/About to throw/, 'minion job has the right output';
    ok !$schema->resultset('GruTasks')->find($ids->{gru_id}), 'gru task no longer exists';
    is $t->app->minion->job($ids->{minion_id})->info->{state}, 'failed', 'minion job is finished';
    like $t->app->minion->job($ids->{minion_id})->info->{result}, qr/Thrown fail/,
      'minion job has the right error message';
};

# prevent writing to a log file to enable use of combined_like in the following tests
$t->app->log(Mojo::Log->new(level => 'debug'));

subtest 'download assets with correct permissions' => sub {
    my $local_domain = "127.0.0.1";
    my $assetsource  = "http://$local_domain:$mojo_port/tests/99926/file/autoinst-log.txt";
    my $assetpath    = 't/data/openqa/share/factory/iso/Core-7.2.iso';

    # be sure the asset does not exist from a previous test run
    unlink($assetpath);

    combined_like { run_gru_job($t->app, 'download_asset' => [$assetsource, $assetpath, 0]) }
    qr/Host "$local_domain" .* is not on the whitelist \(which is empty\)/, 'download refused if whitelist empty';

    $t->app->config->{global}->{download_domains} = 'foo';
    combined_like { run_gru_job($t->app, 'download_asset' => [$assetsource, $assetpath, 0]) }
    qr/Host "$local_domain" .* is not on the whitelist/, 'download refused if host not on whitelist';

    $t->app->config->{global}->{download_domains} .= " $local_domain";
    combined_like { run_gru_job($t->app, 'download_asset' => [$assetsource . '.foo', $assetpath, 0]) }
    qr/failed: 404 Not Found/, 'error code logged';

    my $does_not_exist = $assetsource . '.does_not_exist';
    my $info;
    combined_like { $info = run_gru_job($t->app, 'download_asset' => [$does_not_exist, $assetpath, 0]) }
    qr/failed: 404 Not Found.*Downloading "$does_not_exist" failed/s, 'everything logged';
    is $info->{state}, 'failed', 'job failed';
    like $info->{result}, qr/Downloading "$does_not_exist" failed because of too many download errors/,
      'reason provided';

    combined_like { run_gru_job($t->app, 'download_asset' => [$assetsource, $assetpath, 0]) }
    qr/Download of "$assetpath" successful/, 'download logged';
    ok -f $assetpath, 'asset downloaded';
    is(S_IMODE((stat($assetpath))[2]), 0644, 'asset downloaded with correct permissions');

    combined_like { run_gru_job($t->app, 'download_asset' => [$assetsource, $assetpath, 0]) }
    qr/Skipping download of "$assetsource" to "$assetpath" because file already exists/, 'everything logged';
    ok -f $assetpath, 'asset downloaded';
};

subtest 'finalize job results' => sub {
    # prepare test job
    my %settings = (
        DISTRI  => 'Unicorn',
        FLAVOR  => 'pink',
        VERSION => '42',
        BUILD   => '666',
        ISO     => 'whatever.iso',
        MACHINE => 'RainbowPC',
        ARCH    => 'x86_64',
        TEST    => 'minion',
    );
    my $job = $schema->resultset('Jobs')->create_from_settings(\%settings);
    $job->discard_changes;
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {}});
    $job->update_module('a', {result => 'ok', details => [{title => 'wait_serial', text => 'a-0.txt'}]});
    $job->insert_module({name => 'b', category => 'b', script => 'b', flags => {}});
    $job->update_module('b', {result => 'fail', details => [{title => 'wait_serial', text => 'b-0.txt'}]});
    $job->update;
    $job->discard_changes;
    my $a_details = path($job->result_dir, 'details-a.json');

    # clear any previous finalize_job_results jobs
    my $app    = $t->app;
    my $minion = $app->minion;
    $minion->reset({all => 1});

    subtest 'successful run triggered via $job->done' => sub {
        my $a_txt = path($job->result_dir, 'a-0.txt')->spurt('Foo');
        my $b_txt = path('t/data/14-module-b.txt')->copy_to($job->result_dir . '/b-0.txt');
        $job->done;
        $job->discard_changes;
        is($job->result, OpenQA::Jobs::Constants::FAILED, 'job result is failed');
        $minion->perform_jobs;
        my $minion_jobs = $minion->jobs({tasks => ['finalize_job_results']});
        is($minion_jobs->total, 1, 'one minion job executed')
          and is($minion_jobs->next->{state}, 'finished', 'the minion job succeeded');
        ok(!-e $a_txt);
        ok(!-e $b_txt);
        my @modlist = $job->modules;
        is($modlist[0]->results->{details}->[0]->{text_data}, 'Foo');
        is($modlist[1]->results->{details}->[0]->{text_data}, "正解\n");
        is($a_details->stat->mode & 0644, 0644, 'details JSON globally readable');
    };

    subtest 'enqueue finalize_job_results without job or job which (no longer) exists' => sub {
        run_gru_job($app, finalize_job_results => [$_]) for (undef, 98765);
        is($minion->jobs({tasks => ['finalize_job_results'], states => ['failed']})->total,
            2, 'jobs with invalid job fail');
    };

    subtest 'unsuccessful run where not all modules can be finalized' => sub {
        $minion->reset({all => 1});
        $a_details->spurt('Not {} valid [] JSON');
        run_gru_job($app, finalize_job_results => [$job->id]);
        my $minion_jobs = $minion->jobs({tasks => ['finalize_job_results']});
        if (is($minion_jobs->total, 1, 'one minion job executed')) {
            my $info = $minion_jobs->next;
            is($info->{state}, 'failed', 'the minion job failed');
            like($info->{notes}->{failed_modules}->{a}, qr/malformed JSON string/, 'the minion job failed')
              or diag explain $info->{notes};
        }
    };
};


$webapi->signal('TERM');
$webapi->finish;

done_testing();

# clear gru task queue at end of execution so no 'dangling' tasks
# break subsequent tests; can happen if a subtest creates a task but
# does not execute it, or we crash partway through a subtest...
END {
    $t->app->minion->reset;
}
