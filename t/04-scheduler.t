#!/usr/bin/env perl
# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use DateTime;
use DateTime::Duration;
use OpenQA::Scheduler::Model::Jobs;
use OpenQA::Resource::Locks;
use OpenQA::Resource::Jobs;
use OpenQA::Constants qw(WEBSOCKET_API_VERSION DB_TIMESTAMP_ACCURACY);
use OpenQA::Jobs::Constants;
use OpenQA::Test::Database;
use OpenQA::Test::Utils 'setup_mojo_app_with_default_worker_timeout';
use OpenQA::Utils 'assetdir';
use Test::Mojo;
use Test::MockModule;
use Test::Warnings ':report_warnings';
use OpenQA::Schema::Result::Jobs;
use OpenQA::WebAPI::Controller::API::V1::Worker;
use OpenQA::Test::TimeLimit '10';

setup_mojo_app_with_default_worker_timeout;

# Mangle worker websocket send, and record what was sent
my $mock_result = Test::MockModule->new('OpenQA::Schema::Result::Jobs');
my $sent = {};
my $ws_send_error;
$mock_result->redefine(
    ws_send => sub {
        my ($self, $worker) = @_;
        die $ws_send_error if defined $ws_send_error;
        my $hashref = $self->prepare_for_work($worker);
        $hashref->{assigned_worker_id} = $worker->id;
        $sent->{$worker->id} = {worker => $worker, job => $self};
        return {state => {msg_sent => 1}};
    });

my $schema = OpenQA::Test::Database->new->create;
my $jobs = $schema->resultset('Jobs');
my $t = Test::Mojo->new('OpenQA::Scheduler');

subtest 'Authentication' => sub {
    $t->get_ok('/test')->status_is(404)->content_like(qr/Not found/);
    my $app = $t->app;
    $t->get_ok('/')->status_is(200)->json_is({name => $app->defaults('appname')});
    local $t->app->config->{no_localhost_auth} = 0;
    $t->get_ok('/')->status_is(403)->json_is({error => 'Not authorized'});
};

subtest 'Exception' => sub {
    $t->app->plugins->once(before_dispatch => sub { die 'Just a test exception!' });
    $t->get_ok('/whatever')->status_is(500)->content_like(qr/Just a test exception!/);
    $t->get_ok('/whatever')->status_is(404);
};

subtest 'API' => sub {
    my $mock_scheduler = Test::MockModule->new('OpenQA::Scheduler');
    my $awake = 0;
    $mock_scheduler->redefine(wakeup => sub { $awake++ });
    $t->get_ok('/api/wakeup')->status_is(200)->content_is('ok');
    is $awake, 1, 'scheduler has been woken up';
    $t->get_ok('/api/wakeup')->status_is(200)->content_is('ok');
    is $awake, 2, 'scheduler has been woken up again';
};

sub list_jobs {
    [map { $_->to_hash(assets => 1) } $jobs->complex_query(@_)->all]
}
sub job_get { $jobs->find({id => shift}) }
sub job_get_hash {
    my ($id) = @_;

    my $job = job_get($id);
    return unless $job;
    my $ref = $job->to_hash(assets => 1);
    $ref->{worker_id} = $job->worker_id;
    return $ref;
}

my $current_jobs = list_jobs();
is_deeply($current_jobs, [], 'assert database has no jobs to start with')
  or BAIL_OUT('database not properly initialized');

# test worker_register and worker_get
my $c = OpenQA::WebAPI::Controller::API::V1::Worker->new;
my $workercaps = {};
$workercaps->{cpu_modelname} = 'Rainbow CPU';
$workercaps->{cpu_arch} = 'x86_64';
$workercaps->{cpu_opmode} = '32-bit, 64-bit';
$workercaps->{mem_max} = '4096';
$workercaps->{websocket_api_version} = WEBSOCKET_API_VERSION;
$workercaps->{isotovideo_interface_version} = WEBSOCKET_API_VERSION;
sub register_worker { $c->_register($schema, 'host', '1', $workercaps) }

my ($id, $worker, $worker_db_obj);
subtest 'worker registration' => sub {
    is($id = register_worker, 1, 'new worker registered');

    $worker_db_obj = $schema->resultset('Workers')->find($id);
    $worker = $worker_db_obj->info;

    is($worker->{id}, $id, 'id set');
    is($worker->{host}, 'host', 'host set');
    is($worker->{instance}, '1', 'instance set');
    is(register_worker, $id, 're-registered worker got same id');
};

# test job_create and job_get
my %settings = (
    DISTRI => 'Unicorn',
    FLAVOR => 'pink',
    VERSION => '42',
    BUILD => '666',
    TEST => 'rainbow',
    ISO => 'whatever.iso',
    DESKTOP => 'DESKTOP',
    KVM => 'KVM',
    ISO_MAXSIZE => 1,
    MACHINE => 'RainbowPC',
    ARCH => 'x86_64'
);
my $job_ref = {
    t_finished => undef,
    id => 1,
    name => 'Unicorn-42-pink-x86_64-Build666-rainbow@RainbowPC',
    priority => 40,
    result => 'none',
    settings => {
        DESKTOP => 'DESKTOP',
        DISTRI => 'Unicorn',
        FLAVOR => 'pink',
        VERSION => '42',
        BUILD => '666',
        TEST => 'rainbow',
        ISO => 'whatever.iso',
        ISO_MAXSIZE => 1,
        KVM => 'KVM',
        MACHINE => 'RainbowPC',
        ARCH => 'x86_64',
        NAME => '00000001-Unicorn-42-pink-x86_64-Build666-rainbow@RainbowPC',
        WORKER_CLASS => 'qemu_x86_64',
    },
    assets => {iso => ['whatever.iso']},
    t_started => undef,
    blocked_by_id => undef,
    state => SCHEDULED,
    worker_id => 0,
    clone_id => undef,
    group_id => undef,
    # to be removed
    test => 'rainbow'
};
my $iso = sprintf("%s/iso/%s", assetdir(), $settings{ISO});
my $job = $jobs->create_from_settings(\%settings);
is($job->id, 1, "job_create");

my %settings2 = %settings;
$settings2{NAME} = "OTHER NAME";
$settings2{BUILD} = "44";
my $job2 = $jobs->create_from_settings(\%settings2);
is($job2->id, 2);

subtest 'calling again with same settings' => sub {
    my $job3 = $jobs->create_from_settings(\%settings2);
    is($job3->id, 3, 'calling again with same settings yields new job');
    $jobs->find($job3->id)->delete;
};

$job->set_prio(40);
my $new_job = job_get_hash($job->id);
is_deeply($new_job, $job_ref, "job_get");

subtest 'job listing' => sub {
    my $expected_jobs = [
        {
            t_finished => undef,
            blocked_by_id => undef,
            id => 2,
            name => 'Unicorn-42-pink-x86_64-Build44-rainbow@RainbowPC',
            priority => 50,
            result => 'none',
            t_started => undef,
            state => SCHEDULED,
            test => 'rainbow',
            clone_id => undef,
            group_id => undef,
            assets => {iso => ['whatever.iso']},
            settings => {
                DESKTOP => 'DESKTOP',
                DISTRI => 'Unicorn',
                FLAVOR => 'pink',
                VERSION => '42',
                BUILD => '44',
                TEST => 'rainbow',
                ISO => 'whatever.iso',
                ISO_MAXSIZE => 1,
                KVM => 'KVM',
                MACHINE => 'RainbowPC',
                ARCH => 'x86_64',
                NAME => '00000002-Unicorn-42-pink-x86_64-Build44-rainbow@RainbowPC',
                WORKER_CLASS => 'qemu_x86_64',
            },
        },
        {
            t_finished => undef,
            blocked_by_id => undef,
            id => 1,
            name => 'Unicorn-42-pink-x86_64-Build666-rainbow@RainbowPC',
            priority => 40,
            result => 'none',
            t_started => undef,
            state => SCHEDULED,
            test => 'rainbow',
            clone_id => undef,
            group_id => undef,
            assets => {iso => ['whatever.iso']},
            settings => {
                DESKTOP => 'DESKTOP',
                DISTRI => 'Unicorn',
                FLAVOR => 'pink',
                VERSION => '42',
                BUILD => '666',
                TEST => 'rainbow',
                ISO => 'whatever.iso',
                ISO_MAXSIZE => 1,
                KVM => 'KVM',
                MACHINE => 'RainbowPC',
                ARCH => 'x86_64',
                NAME => '00000001-Unicorn-42-pink-x86_64-Build666-rainbow@RainbowPC',
                WORKER_CLASS => 'qemu_x86_64',
            },
        },
    ];

    $current_jobs = list_jobs();
    is_deeply($current_jobs, $expected_jobs, "All list_jobs");

    my %args = (state => SCHEDULED);
    $current_jobs = list_jobs(%args);
    is_deeply($current_jobs, $expected_jobs, "All list_jobs with state scheduled");

    %args = (state => RUNNING);
    $current_jobs = list_jobs(%args);
    is_deeply($current_jobs, [], "All list_jobs with state running");

    %args = (build => "666");
    $current_jobs = list_jobs(%args);
    is_deeply($current_jobs, [$expected_jobs->[1]], "list_jobs with build");

    %args = (iso => "whatever.iso");
    $current_jobs = list_jobs(%args);
    is_deeply($current_jobs, $expected_jobs, "list_jobs with iso");

    %args = (build => "666", state => SCHEDULED);
    $current_jobs = list_jobs(%args);
    is_deeply($current_jobs, [$expected_jobs->[1]], "list_jobs combining a setting (BUILD) and state");

    %args = (iso => "whatever.iso", build => "666");
    $current_jobs = list_jobs(%args);
    is_deeply($current_jobs, [$expected_jobs->[1]], "list_jobs combining two settings (ISO and BUILD)");

    %args = (build => "whatever.iso", iso => "666");
    $current_jobs = list_jobs(%args);
    is_deeply($current_jobs, [], "list_jobs messing two settings up");

    %args = (ids => [1, 2], state => [SCHEDULED, DONE]);
    $current_jobs = list_jobs(%args);
    is_deeply($current_jobs, $expected_jobs, "jobs with specified IDs and states (array ref)");

    %args = (ids => "2,3", state => "scheduled,done");
    $current_jobs = list_jobs(%args);
    is_deeply($current_jobs, [$expected_jobs->[0]], "jobs with specified IDs (comma list)");
};

# assume the worker has just been seen
my $last_seen = $worker_db_obj->t_seen;
$last_seen->subtract(seconds => DB_TIMESTAMP_ACCURACY);
$worker_db_obj->make_column_dirty('t_seen');
$worker_db_obj->update({t_seen => $last_seen});

subtest 'job grab (WORKER_CLASS mismatch)' => sub {
    my $allocated = OpenQA::Scheduler::Model::Jobs->singleton->schedule();
    $worker_db_obj->discard_changes;
    is(undef, $sent->{$worker->{id}}->{job}, 'job not grabbed due to default WORKER_CLASS');
    is_deeply($allocated, [], 'no workers/jobs allocated');
};

subtest 'job grab (failed to send job to worker)' => sub {
    $worker_db_obj->set_property(WORKER_CLASS => 'qemu_x86_64');
    $ws_send_error = 'fake error';

    my $allocated = OpenQA::Scheduler::Model::Jobs->singleton->schedule();
    $worker_db_obj->discard_changes;
    is_deeply($allocated, [], 'no workers/jobs allocated');
};

subtest 'job grab (successful assignment)' => sub {
    my $rjobs_before = list_jobs(state => RUNNING);
    undef $ws_send_error;
    OpenQA::Scheduler::Model::Jobs->singleton->schedule();
    $worker_db_obj->discard_changes;

    my $grabbed = $sent->{$worker->{id}}->{job}->to_hash;
    my $rjobs_after = list_jobs(state => ASSIGNED);
    ok($grabbed->{settings}->{JOBTOKEN}, 'job token present');
    $job_ref->{settings}->{JOBTOKEN} = $grabbed->{settings}->{JOBTOKEN};
    is_deeply($grabbed->{settings}, $job_ref->{settings}, 'settings correct');
    ok(!$grabbed->{t_started}, 'job start timestamp not present as job is not started');
    is(scalar(@{$rjobs_before}) + 1, scalar(@{$rjobs_after}), 'number of running jobs');
    is($rjobs_after->[-1]->{assigned_worker_id}, 1, 'assigned worker set');

    $grabbed = job_get($job->id);
    is($grabbed->assigned_worker_id, $worker->{id}, 'worker assigned to job');
    is($grabbed->worker->id, $worker->{id}, 'job assigned to worker');
    is($grabbed->state, ASSIGNED, 'job is in assigned state');
};

my ($job_id, $job3_id);

subtest 'worker re-registration' => sub {
    # register worker again with no job while the web UI thinks it has an assigned job
    is(register_worker, $id, 'worker re-registered');

    # the assigned job is supposed to be re-scheduled
    $job->discard_changes;
    $worker_db_obj->discard_changes;
    is($job->state, SCHEDULED, 'previous job has been re-scheduled');
    is($job->result, NONE, 'previous job has no result yet');
    is($job->settings_hash->{JOBTOKEN}, undef, 'the job token of the previous job has been cleared');
    cmp_ok($worker_db_obj->t_seen, '>', $last_seen, 'last seen timestamp of worker updated on registration');
    is($worker_db_obj->job_id, undef, 'previous job is no longer considered the current job of the worker');

    # register worker again with no job while the web UI thinks it as a running job
    $job->update({state => RUNNING});
    $worker_db_obj->update({job_id => $job->id});
    $worker_db_obj->set_property(JOB_TOKEN => 'assume we have a token');
    is(register_worker, $id, 'worker re-registered');

    # the assigned job is supposed to be incompleted
    $job->discard_changes;
    $worker_db_obj->discard_changes;
    is($job->state, DONE, 'previous job has is considered done');
    is($job->result, INCOMPLETE, 'previous job been incompleted');
    is($job->settings_hash->{JOBTOKEN}, undef, 'the job token of the previous job has been cleared');
    is($worker_db_obj->job_id, undef, 'previous job is no longer considered the current job of the worker');

    OpenQA::Scheduler::Model::Jobs->singleton->schedule();
    my $grabbed = $sent->{$worker->{id}}->{job}->to_hash;
    isnt($job->id, $grabbed->{id}, 'new job grabbed') or die diag explain $grabbed;
    isnt($grabbed->{settings}->{JOBTOKEN}, $job_ref->{settings}->{JOBTOKEN}, 'job token differs')
      or die diag explain $grabbed->to_hash;

    # update refs for is_deeply compare
    $job_ref->{settings}->{JOBTOKEN} = $grabbed->{settings}->{JOBTOKEN};
    $job_ref->{settings}->{NAME} = $grabbed->{settings}->{NAME};

    is_deeply($grabbed->{settings}, $job_ref->{settings}, "settings correct");
    $job3_id = $job->id;
    $job_id = $grabbed->{id};
};

subtest 'setting job to done' => sub {
    $job = job_get($job_id);
    is($job->done(result => PASSED), PASSED, 'job_set_done');
    $job = job_get($job_id);
    is($job->state, DONE, 'job_set_done changed state');
    is($job->result, PASSED, 'job_set_done changed result');
    ok($job->t_finished =~ /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, 'job end timestamp updated');
    ok(!$job->settings_hash->{JOBTOKEN}, 'job token not present after job done');

    $current_jobs = list_jobs(result => PASSED);
    is(scalar @{$current_jobs}, 1, "there is one passed job listed");
};

subtest 'set_prio' => sub {
    $jobs->find($job_id)->set_prio(100);
    $job = job_get($job_id);
    is($job->priority, 100, 'prio changed');
};

subtest 'job deletion' => sub {
    my $result = $jobs->find($job_id)->delete;
    my $no_job_id = job_get($job_id);
    ok($result && !defined $no_job_id, 'first job deleted');
    $job->discard_changes;

    $result = $jobs->find($job2->id)->delete;
    $no_job_id = job_get($job2->id);
    ok($result && !defined $no_job_id, '2nd job deleted');

    $result = $jobs->find($job3_id)->delete;
    $no_job_id = job_get($job3_id);
    ok($result && !defined $no_job_id, '3rd job deleted');

    $current_jobs = list_jobs();
    is_deeply($current_jobs, [], 'no jobs listed anymore');
};

my $asset = $schema->resultset('Assets')->register('iso', $settings{ISO});
is($asset->name, $settings{ISO}, 'asset register returns same');

subtest 'test job cancellation after max job scheduled time timeout' => sub {
    my $old_time = (DateTime->now(time_zone => 'UTC') - DateTime::Duration->new(days => 8));
    my $job5 = $jobs->create_from_settings(\%settings);
    $job5->update({t_created => $old_time, state => SCHEDULED, result => NONE});
    undef $ws_send_error;
    OpenQA::Scheduler::Model::Jobs->singleton->schedule();
    $job5->discard_changes;
    is($job5->state, CANCELLED, 'Job 5 is cancelled by scheduler');
    is($job5->result, OBSOLETED, 'Job5 result is OBSOLETED');
    is($job5->reason, 'scheduled for more than 7 days');
};

done_testing;
