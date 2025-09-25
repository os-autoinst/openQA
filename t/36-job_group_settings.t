#!/usr/bin/env perl
# Copyright 2018-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '6';
use OpenQA::Test::Case;
use OpenQA::JobDependencies::Constants;
use OpenQA::JobGroupDefaults;
use Date::Format qw(time2str);
use Time::Seconds;

OpenQA::Test::Case->new->init_data;
my $t = Test::Mojo->new('OpenQA::WebAPI');

# get resultsets
my $schema = $t->app->schema;
my $job_groups = $schema->resultset('JobGroups');
my $parent_groups = $schema->resultset('JobGroupParents');

# create new parent group
my $new_parent_group_id = $parent_groups->create({name => 'new parent group'})->id;
my $new_parent_group = $parent_groups->find($new_parent_group_id);
ok($new_parent_group, 'create new parent group');

# create new job group
my $new_job_group_id = $job_groups->create({name => 'new job group'})->id;
my $new_job_group = $job_groups->find($new_job_group_id);
ok($new_job_group, 'create new job group');

subtest 'defaults of parent group' => sub {
    is($new_parent_group->size_limit_gb, undef);
    is($new_parent_group->default_keep_logs_in_days, OpenQA::JobGroupDefaults::KEEP_LOGS_IN_DAYS);
    is($new_parent_group->default_keep_important_logs_in_days, OpenQA::JobGroupDefaults::KEEP_IMPORTANT_LOGS_IN_DAYS);
    is($new_parent_group->default_keep_results_in_days, OpenQA::JobGroupDefaults::KEEP_RESULTS_IN_DAYS);
    is(
        $new_parent_group->default_keep_important_results_in_days,
        OpenQA::JobGroupDefaults::KEEP_IMPORTANT_RESULTS_IN_DAYS
    );
    is($new_parent_group->default_priority, OpenQA::JobGroupDefaults::PRIORITY);
};

subtest 'defaults of group without parent' => sub {
    is($new_job_group->size_limit_gb, OpenQA::JobGroupDefaults::SIZE_LIMIT_GB);
    is($new_job_group->keep_logs_in_days, OpenQA::JobGroupDefaults::KEEP_LOGS_IN_DAYS);
    is($new_job_group->keep_important_logs_in_days, OpenQA::JobGroupDefaults::KEEP_IMPORTANT_LOGS_IN_DAYS);
    is($new_job_group->keep_results_in_days, OpenQA::JobGroupDefaults::KEEP_RESULTS_IN_DAYS);
    is($new_job_group->keep_important_results_in_days, OpenQA::JobGroupDefaults::KEEP_IMPORTANT_RESULTS_IN_DAYS);
    is($new_job_group->default_priority, OpenQA::JobGroupDefaults::PRIORITY);
};

subtest 'overrideing defaults in settings affects groups' => sub {
    my $config = $t->app->config->{default_group_limits};
    my @fields
      = qw(asset_size_limit log_storage_duration important_log_storage_duration result_storage_duration important_result_storage_duration);
    $config->{$_} += 1000 for (@fields);

    subtest 'defaults for parent group overridden' => sub {
        is($new_parent_group->size_limit_gb, undef);
        is($new_parent_group->default_keep_logs_in_days, OpenQA::JobGroupDefaults::KEEP_LOGS_IN_DAYS + 1000);
        is(
            $new_parent_group->default_keep_important_logs_in_days,
            OpenQA::JobGroupDefaults::KEEP_IMPORTANT_LOGS_IN_DAYS + 1000
        );
        is($new_parent_group->default_keep_results_in_days, OpenQA::JobGroupDefaults::KEEP_RESULTS_IN_DAYS + 1000);
        is(
            $new_parent_group->default_keep_important_results_in_days,
            OpenQA::JobGroupDefaults::KEEP_IMPORTANT_RESULTS_IN_DAYS + 1000
        );
    };

    subtest 'defaults for job group overridden' => sub {
        is($new_job_group->size_limit_gb, OpenQA::JobGroupDefaults::SIZE_LIMIT_GB + 1000);
        is($new_job_group->keep_logs_in_days, OpenQA::JobGroupDefaults::KEEP_LOGS_IN_DAYS + 1000);
        is($new_job_group->keep_important_logs_in_days, OpenQA::JobGroupDefaults::KEEP_IMPORTANT_LOGS_IN_DAYS + 1000);
        is($new_job_group->keep_results_in_days, OpenQA::JobGroupDefaults::KEEP_RESULTS_IN_DAYS + 1000);
        is($new_job_group->keep_important_results_in_days,
            OpenQA::JobGroupDefaults::KEEP_IMPORTANT_RESULTS_IN_DAYS + 1000);
    };
};

subtest 'defaults overridden on parent group level' => sub {
    my @columns
      = qw(size_limit_gb default_keep_logs_in_days default_keep_important_logs_in_days default_keep_results_in_days default_keep_important_results_in_days default_priority);
    for my $column (@columns) {
        $new_parent_group->update({$column => ($new_parent_group->$column // 0) + 1000});
    }

    is($new_parent_group->size_limit_gb, 1000);
    is($new_parent_group->default_keep_logs_in_days, OpenQA::JobGroupDefaults::KEEP_LOGS_IN_DAYS + 2000);
    is(
        $new_parent_group->default_keep_important_logs_in_days,
        OpenQA::JobGroupDefaults::KEEP_IMPORTANT_LOGS_IN_DAYS + 2000
    );
    is($new_parent_group->default_keep_results_in_days, OpenQA::JobGroupDefaults::KEEP_RESULTS_IN_DAYS + 2000);
    is(
        $new_parent_group->default_keep_important_results_in_days,
        OpenQA::JobGroupDefaults::KEEP_IMPORTANT_RESULTS_IN_DAYS + 2000
    );
    is($new_parent_group->default_priority, OpenQA::JobGroupDefaults::PRIORITY + 1000);

    # note: prio is just + 1000 (and not + 2000) because in contrast to the other values the default wasn't changed
    # in previous subtest 'overrideing defaults in settings affects groups'
};

subtest 'job group properties inherited from parent group except for size_limit_gb' => sub {
    $new_job_group->update({parent_id => $new_parent_group_id});

    is($new_job_group->size_limit_gb, OpenQA::JobGroupDefaults::SIZE_LIMIT_GB + 1000);
    is($new_job_group->keep_logs_in_days, OpenQA::JobGroupDefaults::KEEP_LOGS_IN_DAYS + 2000);
    is($new_job_group->keep_important_logs_in_days, OpenQA::JobGroupDefaults::KEEP_IMPORTANT_LOGS_IN_DAYS + 2000);
    is($new_job_group->keep_results_in_days, OpenQA::JobGroupDefaults::KEEP_RESULTS_IN_DAYS + 2000);
    is($new_job_group->keep_important_results_in_days, OpenQA::JobGroupDefaults::KEEP_IMPORTANT_RESULTS_IN_DAYS + 2000);
    is($new_job_group->default_priority, OpenQA::JobGroupDefaults::PRIORITY + 1000);
};

subtest 'inherited job group properties overridden' => sub {
    my @columns
      = qw(size_limit_gb keep_logs_in_days keep_important_logs_in_days keep_results_in_days keep_important_results_in_days default_priority);
    for my $column (@columns) {
        $new_job_group->update({$column => $new_job_group->$column + 1000});
    }

    is($new_job_group->size_limit_gb, OpenQA::JobGroupDefaults::SIZE_LIMIT_GB + 2000);
    is($new_job_group->keep_logs_in_days, OpenQA::JobGroupDefaults::KEEP_LOGS_IN_DAYS + 3000);
    is($new_job_group->keep_important_logs_in_days, OpenQA::JobGroupDefaults::KEEP_IMPORTANT_LOGS_IN_DAYS + 3000);
    is($new_job_group->keep_results_in_days, OpenQA::JobGroupDefaults::KEEP_RESULTS_IN_DAYS + 3000);
    is($new_job_group->keep_important_results_in_days, OpenQA::JobGroupDefaults::KEEP_IMPORTANT_RESULTS_IN_DAYS + 3000);
    is($new_job_group->default_priority, OpenQA::JobGroupDefaults::PRIORITY + 2000);
};

subtest 'retention period of infinity does not break cleanup' => sub {
    my @retention_params = (keep_results_in_days => 0, keep_logs_in_days => 0, keep_jobs_in_days => 0);
    my $group = $job_groups->create({name => 'yet another group', @retention_params});
    $group->jobs->create({TEST => 'very old job', t_finished => '0001-01-01 00:00:00'});
    $group->discard_changes;
    $group->limit_results_and_logs;
    $group->discard_changes;
    is $group->jobs->count, 1, 'very old job still there';
};

subtest 'retentions for job in database and job results are effective' => sub {
    my $now = time;
    my $zero_days_old = time2str('%Y-%m-%d %H:%M:%S', $now, 'UTC');
    my $five_days_old = time2str('%Y-%m-%d %H:%M:%S', $now - ONE_DAY * 5, 'UTC');
    my $group = $job_groups->create({name => 'another group', keep_results_in_days => 4});
    my $jobs = $schema->resultset('Jobs');
    my $job = $group->jobs->create({TEST => 'job', t_finished => $five_days_old});
    my $parallel_job = $jobs->create({TEST => 'parallel_job', t_finished => $zero_days_old});
    $job->children->create({child_job_id => $parallel_job->id, dependency => PARALLEL});
    $job->create_result_dir;
    $group->discard_changes;
    $group->limit_results_and_logs;
    $group->discard_changes;
    my $result_dir = $job->result_dir;
    is $group->jobs->count, 1, 'job still in database as only keep_results_in_days was set';
    ok !-d $result_dir, "result dir '$result_dir' no longer exists";

    $group->update({keep_jobs_in_days => 4});
    $group->limit_results_and_logs;
    $group->discard_changes;
    is $jobs->search({id => $parallel_job->id})->count, 1, 'dependent job still there';
    is $group->jobs->count, 0, 'job has been deleted from database via keep_jobs_in_days';
};

subtest 'new "null" job group uses configured default group limits' => sub {
    my $g = $job_groups->new({});
    my $c = $t->app->config->{no_group_limits};
    ok !$g->in_storage, 'new group not in storage';
    is $g->keep_logs_in_days, $c->{log_storage_duration}, 'log_storage_duration';
    is $g->keep_important_logs_in_days, $c->{important_log_storage_duration}, 'important_log_storage_duration';
    is $g->keep_results_in_days, $c->{result_storage_duration}, 'result_storage_duration';
    is $g->keep_important_results_in_days, $c->{important_result_storage_duration}, 'important_result_storage_duration';
};

subtest 'finding expired jobs' => sub {
    my $find_expired_jobs = sub () {
        [sort map { $_->TEST } @{$new_job_group->find_expired_jobs}]
    };
    my $two_days_old = time2str('%Y-%m-%d %H:%M:%S', time - ONE_DAY * 3, 'UTC');
    my $four_days_old = time2str('%Y-%m-%d %H:%M:%S', time - ONE_DAY * 4, 'UTC');
    my $jobs = $new_job_group->jobs;

    $jobs->create({TEST => 'regular', t_finished => $two_days_old, BUILD => '1000'});
    $jobs->create({TEST => 'important', t_finished => $four_days_old, BUILD => '1001'});
    $new_job_group->comments->create({text => 'tag:1001:important:test', user_id => 1});
    $new_job_group->update({keep_jobs_in_days => 1, keep_important_jobs_in_days => 1});
    $new_job_group->discard_changes;
    is_deeply $find_expired_jobs->(), ['important', 'regular'], 'both jobs expired with same expiration setting';

    $new_job_group->update({keep_jobs_in_days => 1, keep_important_jobs_in_days => 5});
    $new_job_group->discard_changes;
    is_deeply $find_expired_jobs->(), ['regular'], 'only regular job expired if retention of important jobs extended';

    $new_job_group->update({keep_jobs_in_days => 5, keep_important_jobs_in_days => 1});
    $new_job_group->discard_changes;
    is_deeply $find_expired_jobs->(), ['important'], 'only important job expired if retentions reversed';
};

done_testing();
