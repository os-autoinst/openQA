#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use DateTime;
use Mojo::Log;
use OpenQA::App;
use OpenQA::Jobs::Constants;
use OpenQA::Scheduler;
use OpenQA::Test::TimeLimit '20';
use OpenQA::Test::Database;
use Test::Mojo;
use Test::MockModule;
use Test::Output qw(combined_like);
use Test::Warnings ':report_warnings';

my $schema = OpenQA::Test::Database->new->create(fixtures_glob => '01-jobs.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');
my $app = $t->app;
my $minion = $app->minion;
my $gru_tasks = $schema->resultset('GruTasks');
my $gru_dependencies = $schema->resultset('GruDependencies');
my $jobs = $schema->resultset('Jobs');
my $job = $jobs->find(99927);
OpenQA::App->set_singleton($app);
$app->log(Mojo::Log->new(level => 'info'));
$app->config->{misc_limits}->{gru_task_reconcile_grace} = 0;
$minion->add_task(test_gru_task => sub { });

sub reset_job ($job) { $job->update({state => SCHEDULED, result => NONE, reason => undef}) }

sub enqueue_gru_task ($app, $job = undef) { $app->gru->enqueue('test_gru_task', [], {}, $job ? [$job->id] : []) }

sub dequeue_minion_job ($minion, $id) {
    my $worker = $minion->worker->register;
    return ($worker->dequeue(0, {id => $id}), $worker);
}

sub make_gru_task_old ($id) {
    my $dt = DateTime->now(time_zone => 'UTC')->subtract(hours => 2);
    $gru_tasks->find($id)->update({t_created => $schema->storage->datetime_parser->format_datetime($dt)});
}

subtest 'failed Minion job is reconciled' => sub {
    reset_job($job);
    my $ids = enqueue_gru_task($app, $job);
    make_gru_task_old($ids->{gru_id});
    my ($minion_job, $worker) = dequeue_minion_job($minion, $ids->{minion_id});
    $minion->backend->fail_job(
        $ids->{minion_id},
        $minion_job->info->{retries},
        'Job terminated unexpectedly (exit code: 11, signal: 0)'
    );
    $worker->unregister;
    combined_like { $app->gru->reconcile_gru_tasks } qr/Failing Gru task \d+ because its Minion job failed/,
      'failure logged';
    is $gru_tasks->find($ids->{gru_id}), undef, 'Gru task deleted';
    is $gru_dependencies->count, 0, 'dependency deleted';
    $job->discard_changes;
    is $job->result, INCOMPLETE, 'dependent job marked as incomplete';
    like $job->reason, qr/preparation failed: Job terminated unexpectedly/, 'reason passed to dependent job';
};

subtest 'missing Minion job is reconciled' => sub {
    reset_job($job);
    my $ids = enqueue_gru_task($app, $job);
    make_gru_task_old($ids->{gru_id});
    $minion->backend->remove_job($ids->{minion_id});
    combined_like { $app->gru->reconcile_gru_tasks } qr/Failing Gru task \d+ because no matching Minion job exists/,
      'missing job logged';
    is $gru_tasks->find($ids->{gru_id}), undef, 'Gru task deleted';
    is $gru_dependencies->count, 0, 'dependency deleted';
    $job->discard_changes;
    is $job->result, INCOMPLETE, 'dependent job marked as incomplete';
};

subtest 'finished Minion job with leftover Gru task is reconciled' => sub {
    reset_job($job);
    my $ids = enqueue_gru_task($app, $job);
    make_gru_task_old($ids->{gru_id});
    my ($minion_job, $worker) = dequeue_minion_job($minion, $ids->{minion_id});
    $minion->backend->finish_job($ids->{minion_id}, $minion_job->info->{retries}, 'done');
    $worker->unregister;
    combined_like { $app->gru->reconcile_gru_tasks } qr/Deleting Gru task \d+ because its Minion job finished/,
      'finished job logged';
    is $gru_tasks->find($ids->{gru_id}), undef, 'Gru task deleted';
    is $gru_dependencies->count, 0, 'dependency deleted';
    $job->discard_changes;
    is $job->state, SCHEDULED, 'dependent job remains scheduled';
};

subtest 'user error in finished Minion job is reconciled as failure' => sub {
    reset_job($job);
    my $ids = enqueue_gru_task($app, $job);
    make_gru_task_old($ids->{gru_id});
    my ($minion_job, $worker) = dequeue_minion_job($minion, $ids->{minion_id});
    $minion_job->note(user_error => 'bad input');
    $minion->backend->finish_job($ids->{minion_id}, $minion_job->info->{retries}, 'done');
    $worker->unregister;
    combined_like { $app->gru->reconcile_gru_tasks } qr/user error: bad input/, 'user error logged';
    is $gru_tasks->find($ids->{gru_id}), undef, 'Gru task deleted';
    $job->discard_changes;
    is $job->result, INCOMPLETE, 'dependent job marked as incomplete';
    like $job->reason, qr/preparation failed: bad input/, 'user error passed to dependent job';
};

subtest 'pending Minion job is not reconciled' => sub {
    reset_job($job);
    my $ids = enqueue_gru_task($app, $job);
    make_gru_task_old($ids->{gru_id});
    $app->gru->reconcile_gru_tasks;
    is $gru_tasks->find($ids->{gru_id})->id, $ids->{gru_id}, 'Gru task kept';
    is $gru_dependencies->count, 1, 'dependency kept';
    $minion->backend->remove_job($ids->{minion_id});
    $gru_tasks->find($ids->{gru_id})->delete;
};

subtest 'obsolete Minion job is not considered a pending job' => sub {
    reset_job($job);
    my $ids = enqueue_gru_task($app, $job);
    make_gru_task_old($ids->{gru_id});
    my ($minion_job, $worker) = dequeue_minion_job($minion, $ids->{minion_id});
    $minion_job->note(obsolete => 1);
    $minion->backend->fail_job($ids->{minion_id}, $minion_job->info->{retries}, 'obsolete');
    $worker->unregister;
    combined_like { $app->gru->reconcile_gru_tasks } qr/Failing Gru task \d+ because no matching Minion job exists/,
      'obsolete job treated as missing';
    is $gru_tasks->find($ids->{gru_id}), undef, 'Gru task deleted';
    is $gru_dependencies->count, 0, 'dependency deleted';
};

subtest 'recently failed Minion job is not reconciled immediately' => sub {
    reset_job($job);
    my $ids = enqueue_gru_task($app, $job);
    make_gru_task_old($ids->{gru_id});
    my ($minion_job, $worker) = dequeue_minion_job($minion, $ids->{minion_id});
    local $app->config->{misc_limits}->{gru_task_reconcile_grace} = 4 * 60 * 60;
    $minion->backend->fail_job($ids->{minion_id}, $minion_job->info->{retries}, 'temporary failure');
    $worker->unregister;
    $app->gru->reconcile_gru_tasks;
    is $gru_tasks->find($ids->{gru_id})->id, $ids->{gru_id}, 'Gru task kept';
    $minion->backend->remove_job($ids->{minion_id});
    $gru_tasks->find($ids->{gru_id})->delete;
};

subtest 'errors during reconciliation are logged' => sub {
    my $mock = Test::MockModule->new('OpenQA::Shared::Plugin::Gru');
    $mock->redefine(_reconcile_gru_tasks => sub { die 'reconciliation failed' });
    combined_like { $app->gru->reconcile_gru_tasks } qr/Failed to reconcile Gru tasks: reconciliation failed/,
      'reconciliation error logged';
};

done_testing;
