#!/usr/bin/env perl
# Copyright 2014-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Jobs::Constants;
use OpenQA::JobDependencies::Constants;
use OpenQA::Resource::Jobs;
use OpenQA::Resource::Locks;
use OpenQA::Utils;
use OpenQA::Test::Database;
use OpenQA::Test::Utils qw(assume_all_assets_exist embed_server_for_testing);
use OpenQA::Test::TimeLimit '20';
use OpenQA::WebSockets::Client;
use Test::Mojo;
use Test::Warnings ':report_warnings';

my $schema = OpenQA::Test::Database->new->create(fixtures_glob => '01-jobs.pl 06-job_dependencies.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');
assume_all_assets_exist;

embed_server_for_testing(
    server_name => 'OpenQA::WebSockets',
    client => OpenQA::WebSockets::Client->singleton,
);

sub list_jobs {
    [map { $_->to_hash() } $schema->resultset('Jobs')->all];
}

sub job_get_rs {
    my ($id) = @_;
    return $schema->resultset("Jobs")->find({id => $id});
}

sub job_get {
    my $job = job_get_rs(@_);
    return unless $job;
    return $job->to_hash;
}

ok($schema, "create database") || BAIL_OUT("failed to create database");

my $current_jobs = list_jobs();
ok(@$current_jobs, "have jobs");

my $job1 = job_get(99927);
is($job1->{state}, OpenQA::Jobs::Constants::SCHEDULED, 'trying to duplicate scheduled job');
my $job = job_get_rs(99927)->auto_duplicate;
is($job, 'Job 99927 is still scheduled', 'duplication rejected');

$job1 = job_get(99926);
is_deeply(
    job_get_rs(99926)->cluster_jobs,
    {
        99926 => {
            parallel_parents => [],
            chained_parents => [],
            directly_chained_parents => [],
            parallel_children => [],
            chained_children => [],
            directly_chained_children => [],
            is_parent_or_initial_job => 1,
            ok => 0,
            state => DONE,
        },
    },
    '99926 has no siblings and is DONE'
);
$job = job_get_rs(99926)->auto_duplicate;
ok(defined $job, "duplication works");
isnt($job->id, $job1->{id}, 'clone id is different than original job id');

my $jobs = list_jobs();
is(@$jobs, @$current_jobs + 1, "one more job after duplicating one job");

$current_jobs = $jobs;

my $job2 = job_get($job->id);
is(delete $job2->{origin_id}, delete $job1->{id}, 'original job');

# compare cloned and original job ignoring fields which are supposed to be different
# note: Assets are assigned during job grab and not cloned.
for my $job ($job1, $job2) {
    delete $job->{$_} for (qw(id state result reason t_finished t_started assets));
    delete $job->{settings}->{NAME};    # has job id as prefix
}
is_deeply($job1, $job2, 'duplicated job equal');

subtest 'restart job which is still scheduled' => sub {
    my $res = OpenQA::Resource::Jobs::job_restart([99927]);
    is_deeply($res->{duplicates}, [], 'scheduled job not considered') or diag explain $res->{duplicates};
};

subtest 'restart job which has already been cloned' => sub {
    my $res = OpenQA::Resource::Jobs::job_restart([99926]);
    is_deeply($res->{duplicates}, [], 'no job ids returned') or diag explain $res->{duplicates};
    is_deeply($res->{errors}, ['Specified job 99926 has already been cloned as 99982'], 'error returned')
      or diag explain $res->{errors};
    is_deeply($res->{warnings}, [], 'no warnings') or diag explain $res->{warnings};
};

$jobs = list_jobs();
is_deeply($jobs, $current_jobs, "jobs unchanged after restarting scheduled job");

subtest 'cancel job' => sub {
    $job1 = job_get(99927);
    job_get_rs(99927)->cancel;
    $job1 = job_get(99927);
    is($job1->{state}, 'cancelled', 'scheduled job cancelled after cancel');
};

subtest 'restart with (directly) chained child' => sub {

    sub create_parent_and_sibling_for_99973 {
        my ($dependency_type) = @_;
        my $dependencies = $schema->resultset('JobDependencies');
        $dependencies->create({parent_job_id => 99926, child_job_id => 99937, dependency => $dependency_type});
        $dependencies->create({parent_job_id => 99926, child_job_id => 99927, dependency => $dependency_type});
        $schema->resultset('Jobs')->find(99926)->update({clone_id => undef});
    }

    $schema->txn_begin;
    create_parent_and_sibling_for_99973(OpenQA::JobDependencies::Constants::CHAINED);

    # check state before restarting (dependency is supposed to be chained as defined in the fixtures)
    is_deeply(
        job_get_rs(99937)->cluster_jobs,
        {
            99937 => {
                is_parent_or_initial_job => 1,
                ok => 0,
                state => DONE,
                chained_parents => [99926],
                chained_children => [99938],
                parallel_parents => [],
                parallel_children => [],
                directly_chained_parents => [],
                directly_chained_children => [],
            },
            99938 => {
                is_parent_or_initial_job => 0,
                ok => 0,
                state => DONE,
                chained_parents => [99937],
                chained_children => [],
                parallel_parents => [],
                parallel_children => [],
                directly_chained_parents => [],
                directly_chained_children => [],
            },
        },
        '99937 has one chained child and one chained parent; only the child is considered for restarting'
    );
    my $job_before_restart = job_get(99937);

    # restart the job
    my $duplicated = OpenQA::Resource::Jobs::job_restart([99937])->{duplicates};
    is(scalar @$duplicated, 1, 'one job id returned');
    my $job_after_restart = job_get(99937);

    # check new job and whether clone is tracked
    like($job_after_restart->{clone_id}, qr/\d+/, 'clone is tracked');
    delete $job_before_restart->{clone_id};
    delete $job_after_restart->{clone_id};
    is_deeply($job_before_restart, $job_after_restart, 'done job unchanged after restart');
    $job_after_restart = job_get($duplicated->[0]->{99937});
    isnt($job_before_restart->{id}, $job_after_restart->{id}, 'new job has a different id');
    is($job_after_restart->{state}, 'scheduled', 'new job is scheduled');
    is(job_get_rs(99926)->clone_id, undef, 'chained parent has not been cloned');
    is(job_get_rs(99927)->clone_id, undef, 'chained sibling has not been cloned');
    isnt(job_get_rs(99938)->clone_id, undef, 'chained child has been cloned');

    # roll back and do the same once more for directly chained dependencies (which should not make a difference)
    $schema->txn_rollback;
    $schema->resultset('JobDependencies')->search({parent_job_id => 99937, child_job_id => 99938})
      ->update({dependency => OpenQA::JobDependencies::Constants::DIRECTLY_CHAINED});
    create_parent_and_sibling_for_99973(OpenQA::JobDependencies::Constants::DIRECTLY_CHAINED);
    is_deeply(
        job_get_rs(99937)->cluster_jobs,
        {
            99926 => {
                children_skipped => 1,
                is_parent_or_initial_job => 1,
                ok => 0,
                state => DONE,
                chained_parents => [],
                chained_children => [],
                parallel_parents => [],
                parallel_children => [],
                directly_chained_parents => [],
                directly_chained_children => [],
            },
            99937 => {
                is_parent_or_initial_job => 1,
                ok => 0,
                state => DONE,
                chained_parents => [],
                chained_children => [],
                parallel_parents => [],
                parallel_children => [],
                directly_chained_parents => [99926],
                directly_chained_children => [99938],
            },
            99938 => {
                is_parent_or_initial_job => 0,
                ok => 0,
                state => DONE,
                chained_parents => [],
                chained_children => [],
                parallel_parents => [],
                parallel_children => [],
                directly_chained_parents => [99937],
                directly_chained_children => [],
            },
        },
        '99937 has one directly chained child and one directly chained parent; '
          . 'parent considered for restarting but not siblings'
    );
    $job_before_restart = job_get(99937);

    # restart the job
    my $res;
    subtest 'restart prevented by directly chained parent' => sub {
        $res = OpenQA::Resource::Jobs::job_restart([99937]);
        like($res->{errors}->[0], qr/Direct parent 99926 needs to be cloned as well/, 'error message');
        is(scalar @{$res->{duplicates}}, 0, 'no duplicates');
    } or diag explain $res;
    subtest 'restarting direct parent not prevented' => sub {
        $schema->txn_begin;
        $res = OpenQA::Resource::Jobs::job_restart([99926]);
        is(scalar @{$res->{errors}}, 0, 'no errors');
        is(scalar @{$res->{duplicates}}, 1, 'one duplicate');
        $schema->txn_rollback;
    } or diag explain $res;
    subtest 'restart enforced despite directly chained parent' => sub {
        $res = OpenQA::Resource::Jobs::job_restart([99937], force => 1);
        is(scalar @{$res->{errors}}, 0, 'no errors');
        is(scalar @{$res->{duplicates}}, 1, 'one duplicate');
    } or diag explain $res;

    # check new job and whether clone is tracked
    $job_after_restart = job_get(99937);
    like($job_after_restart->{clone_id}, qr/\d+/, 'clone is tracked');
    delete $job_before_restart->{clone_id};
    delete $job_after_restart->{clone_id};
    is_deeply($job_before_restart, $job_after_restart, 'done job unchanged after restart');
    $job_after_restart = job_get($res->{duplicates}->[0]->{99937});
    isnt($job_before_restart->{id}, $job_after_restart->{id}, 'new job has a different id');
    is($job_after_restart->{state}, 'scheduled', 'new job is scheduled');
    isnt(job_get_rs(99926)->clone_id, undef, 'directly chained parent has been cloned');
    is(job_get_rs(99927)->clone_id, undef, 'directly chained sibling has not been cloned');
    isnt(job_get_rs(99938)->clone_id, undef, 'directly chained child has been cloned');

    $jobs = list_jobs();
    is(@$jobs, @$current_jobs + 3, 'three more jobs after restarting done job with chained child dependency');
    $current_jobs = $jobs;
};

# check state before restarting job with parallel dependencies (that dependency is set in fixtures)
is_deeply(
    job_get_rs(99963)->cluster_jobs,
    {
        99963 => {
            is_parent_or_initial_job => 1,
            ok => 0,
            state => RUNNING,
            chained_parents => [],
            chained_children => [],
            parallel_parents => [99961],
            parallel_children => [],
            directly_chained_parents => [],
            directly_chained_children => [],
        },
        99961 => {
            is_parent_or_initial_job => 1,
            ok => 0,
            state => RUNNING,
            chained_parents => [],
            chained_children => [],
            parallel_parents => [],
            parallel_children => [99963],
            directly_chained_parents => [],
            directly_chained_children => [],
        }
    },
    '99963 has one parallel parent'
);
OpenQA::Resource::Jobs::job_restart([99963]);

$jobs = list_jobs();
is(@$jobs, @$current_jobs + 2, "two more job after restarting running job with parallel dependency");

$job1 = job_get(99963);
job_get_rs(99963)->cancel;
$job2 = job_get(99963);

is_deeply($job1, $job2, "running job unchanged after cancel");

my $job3 = job_get(99938)->{clone_id};
job_get_rs($job3)->done(result => OpenQA::Jobs::Constants::INCOMPLETE);
$job3 = job_get($job3);
my $round1 = job_get_rs($job3->{id})->auto_duplicate({dup_type_auto => 1});
ok(defined $round1, "auto-duplicate works");
$job3 = job_get($round1->id);
# need to change state from scheduled
$job3 = job_get($round1->id);
job_get_rs($job3->{id})->done(result => OpenQA::Jobs::Constants::INCOMPLETE);
$round1->discard_changes;
my $round2 = $round1->auto_duplicate({dup_type_auto => 1});
ok(defined $round2, "auto-duplicate works");
$job3 = job_get($round2->id);
# need to change state from scheduled
job_get_rs($job3->{id})->done(result => OpenQA::Jobs::Constants::INCOMPLETE);
$round2->discard_changes;
my $round3 = $round2->auto_duplicate({dup_type_auto => 1});
ok(defined $round3, "auto-duplicate works");
$job3 = job_get($round3->id);
# need to change state from scheduled
job_get_rs($job3->{id})->done(result => OpenQA::Jobs::Constants::INCOMPLETE);

# need to change state from scheduled
$job3 = job_get($round3->id);
job_get_rs($job3->{id})->done(result => OpenQA::Jobs::Constants::INCOMPLETE);
my $round5 = job_get_rs($round3->id)->auto_duplicate;
ok(defined $round5, "manual-duplicate works");
$job3 = job_get($round5->id);

done_testing;
