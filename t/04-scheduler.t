#!/usr/bin/env perl -w

# Copyright (C) 2014 SUSE Linux Products GmbH
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
use OpenQA::Scheduler::Model::Jobs;
use OpenQA::Resource::Locks;
use OpenQA::Resource::Jobs;
use OpenQA::Constants 'WEBSOCKET_API_VERSION';
use OpenQA::Jobs::Constants;
use OpenQA::Test::Database;
use OpenQA::Utils 'assetdir';
use Test::Mojo;
use Test::MockModule;
use Test::More;
use Test::Warnings;
use Test::Output qw(stderr_like);
use OpenQA::Schema::Result::Jobs;

my $sent = {};

# Mangle worker websocket send, and record what was sent
my $mock_result = Test::MockModule->new('OpenQA::Schema::Result::Jobs');
$mock_result->mock(
    ws_send => sub {
        my ($self, $worker) = @_;
        my $hashref = $self->prepare_for_work($worker);
        $hashref->{assigned_worker_id} = $worker->id;
        $sent->{$worker->id} = {worker => $worker, job => $self};
        return {state => {msg_sent => 1}};
    });

my $schema = OpenQA::Test::Database->new->create(skip_fixtures => 1);

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
    my $awake          = 0;
    $mock_scheduler->mock(wakeup => sub { $awake++ });
    $t->get_ok('/api/wakeup')->status_is(200)->content_is('ok');
    is $awake, 1, 'scheduler has been woken up';
    $t->get_ok('/api/wakeup')->status_is(200)->content_is('ok');
    is $awake, 2, 'scheduler has been woken up again';
};

sub list_jobs {
    my %args = @_;
    [map { $_->to_hash(assets => 1) } $schema->resultset('Jobs')->complex_query(%args)->all];
}

sub job_get {
    my ($id) = @_;
    my $job = $schema->resultset("Jobs")->find({id => $id});
    return $job;
}

sub job_get_hash {
    my ($id) = @_;

    my $job = job_get($id);
    return unless $job;
    my $ref = $job->to_hash(assets => 1);
    $ref->{worker_id} = $job->worker_id;
    return $ref;
}

my $result;

sub nots {
    my $h  = shift;
    my @ts = @_;
    unshift @ts, 't_updated', 't_created';
    for (@ts) {
        delete $h->{$_};
    }
    return $h;
}

my $current_jobs = list_jobs();
is_deeply($current_jobs, [], "assert database has no jobs to start with")
  or BAIL_OUT("database not properly initialized");

# Testing worker_register and worker_get
# New worker

my $workercaps = {};
$workercaps->{cpu_modelname}                = 'Rainbow CPU';
$workercaps->{cpu_arch}                     = 'x86_64';
$workercaps->{cpu_opmode}                   = '32-bit, 64-bit';
$workercaps->{mem_max}                      = '4096';
$workercaps->{websocket_api_version}        = WEBSOCKET_API_VERSION;
$workercaps->{isotovideo_interface_version} = WEBSOCKET_API_VERSION;

use OpenQA::WebAPI::Controller::API::V1::Worker;
my $c = OpenQA::WebAPI::Controller::API::V1::Worker->new;

sub register_worker {
    return $c->_register($schema, 'host', '1', $workercaps);
}

my ($id, $worker, $worker_db_obj);
subtest 'worker registration' => sub {
    is($id = register_worker, 1, 'new worker registered');

    $worker_db_obj = $schema->resultset('Workers')->find($id);
    $worker        = $worker_db_obj->info;

    is($worker->{id},       $id,    'id set');
    is($worker->{host},     'host', 'host set');
    is($worker->{instance}, '1',    'instance set');
    is(register_worker,     $id,    're-registered worker got same id');
};

# Testing job_create and job_get
my %settings = (
    DISTRI      => 'Unicorn',
    FLAVOR      => 'pink',
    VERSION     => '42',
    BUILD       => '666',
    TEST        => 'rainbow',
    ISO         => 'whatever.iso',
    DESKTOP     => 'DESKTOP',
    KVM         => 'KVM',
    ISO_MAXSIZE => 1,
    MACHINE     => "RainbowPC",
    ARCH        => 'x86_64'
);

my $job_ref = {
    t_finished => undef,
    id         => 1,
    name       => 'Unicorn-42-pink-x86_64-Build666-rainbow@RainbowPC',
    priority   => 40,
    result     => 'none',
    settings   => {
        DESKTOP      => "DESKTOP",
        DISTRI       => 'Unicorn',
        FLAVOR       => 'pink',
        VERSION      => '42',
        BUILD        => '666',
        TEST         => 'rainbow',
        ISO          => 'whatever.iso',
        ISO_MAXSIZE  => 1,
        KVM          => "KVM",
        MACHINE      => "RainbowPC",
        ARCH         => 'x86_64',
        NAME         => '00000001-Unicorn-42-pink-x86_64-Build666-rainbow@RainbowPC',
        WORKER_CLASS => 'qemu_x86_64',
    },
    assets => {
        iso => ['whatever.iso'],
    },
    t_started     => undef,
    blocked_by_id => undef,
    state         => "scheduled",
    worker_id     => 0,
    clone_id      => undef,
    group_id      => undef,
    # to be removed
    test => 'rainbow'
};

my $iso = sprintf("%s/iso/%s", assetdir(), $settings{ISO});
my $job = $schema->resultset('Jobs')->create_from_settings(\%settings);
is($job->id, 1, "job_create");

my %settings2 = %settings;
$settings2{NAME}  = "OTHER NAME";
$settings2{BUILD} = "44";
my $job2 = $schema->resultset('Jobs')->create_from_settings(\%settings2);
is($job2->id, 2);

subtest 'calling again with same settings' => sub {
    my $job3 = $schema->resultset('Jobs')->create_from_settings(\%settings2);
    is($job3->id, 3, 'calling again with same settings yields new job');
    $schema->resultset('Jobs')->find($job3->id)->delete;
};

$job->set_prio(40);
my $new_job = job_get_hash($job->id);
is_deeply($new_job, $job_ref, "job_get");

# Testing list_jobs
my $jobs = [
    {
        t_finished    => undef,
        blocked_by_id => undef,
        id            => 2,
        name          => 'Unicorn-42-pink-x86_64-Build44-rainbow@RainbowPC',
        priority      => 50,
        result        => 'none',
        t_started     => undef,
        state         => "scheduled",
        test          => 'rainbow',
        clone_id      => undef,
        group_id      => undef,
        settings      => {
            DESKTOP      => "DESKTOP",
            DISTRI       => 'Unicorn',
            FLAVOR       => 'pink',
            VERSION      => '42',
            BUILD        => '44',
            TEST         => 'rainbow',
            ISO          => 'whatever.iso',
            ISO_MAXSIZE  => 1,
            KVM          => "KVM",
            MACHINE      => "RainbowPC",
            ARCH         => 'x86_64',
            NAME         => '00000002-Unicorn-42-pink-x86_64-Build44-rainbow@RainbowPC',
            WORKER_CLASS => 'qemu_x86_64',
        },
        assets => {
            iso => ['whatever.iso'],
        },
    },
    {
        t_finished    => undef,
        blocked_by_id => undef,
        id            => 1,
        name          => 'Unicorn-42-pink-x86_64-Build666-rainbow@RainbowPC',
        priority      => 40,
        result        => 'none',
        t_started     => undef,
        state         => "scheduled",
        test          => 'rainbow',
        clone_id      => undef,
        group_id      => undef,
        settings      => {
            DESKTOP      => "DESKTOP",
            DISTRI       => 'Unicorn',
            FLAVOR       => 'pink',
            VERSION      => '42',
            BUILD        => '666',
            TEST         => 'rainbow',
            ISO          => 'whatever.iso',
            ISO_MAXSIZE  => 1,
            KVM          => "KVM",
            MACHINE      => "RainbowPC",
            ARCH         => 'x86_64',
            NAME         => '00000001-Unicorn-42-pink-x86_64-Build666-rainbow@RainbowPC',
            WORKER_CLASS => 'qemu_x86_64',
        },
        assets => {
            iso => ['whatever.iso'],
        },
    },
];

$current_jobs = list_jobs();
is_deeply($current_jobs, $jobs, "All list_jobs");

my %args = (state => "scheduled");
$current_jobs = list_jobs(%args);
is_deeply($current_jobs, $jobs, "All list_jobs with state scheduled");

%args         = (state => "running");
$current_jobs = list_jobs(%args);
is_deeply($current_jobs, [], "All list_jobs with state running");

%args         = (build => "666");
$current_jobs = list_jobs(%args);
is_deeply($current_jobs, [$jobs->[1]], "list_jobs with build");

%args         = (iso => "whatever.iso");
$current_jobs = list_jobs(%args);
is_deeply($current_jobs, $jobs, "list_jobs with iso");

%args         = (build => "666", state => "scheduled");
$current_jobs = list_jobs(%args);
is_deeply($current_jobs, [$jobs->[1]], "list_jobs combining a setting (BUILD) and state");

%args         = (iso => "whatever.iso", build => "666");
$current_jobs = list_jobs(%args);
is_deeply($current_jobs, [$jobs->[1]], "list_jobs combining two settings (ISO and BUILD)");

%args         = (build => "whatever.iso", iso => "666");
$current_jobs = list_jobs(%args);
is_deeply($current_jobs, [], "list_jobs messing two settings up");

%args         = (ids => [1, 2], state => ["scheduled", "done"]);
$current_jobs = list_jobs(%args);
is_deeply($current_jobs, $jobs, "jobs with specified IDs and states (array ref)");

%args         = (ids => "2,3", state => "scheduled,done");
$current_jobs = list_jobs(%args);
is_deeply($current_jobs, [$jobs->[0]], "jobs with specified IDs (comma list)");

# Testing job_grab (WORKER_CLASS mismatch)
%args = (workerid => $worker->{id}, allocate => 1);
my $rjobs_before = list_jobs(state => 'running');
OpenQA::Scheduler::Model::Jobs->singleton->schedule();
is(undef, $sent->{$worker->{id}}->{job}, 'job not grabbed due to default WORKER_CLASS');

# Testing job_grab
$worker_db_obj->set_property(WORKER_CLASS => 'qemu_x86_64');
OpenQA::Scheduler::Model::Jobs->singleton->schedule();
my $grabbed     = $sent->{$worker->{id}}->{job}->to_hash;
my $rjobs_after = list_jobs(state => 'assigned');

## test and add JOBTOKEN to job_ref after job_grab
ok($grabbed->{settings}->{JOBTOKEN}, "job token present");
$job_ref->{settings}->{JOBTOKEN} = $grabbed->{settings}->{JOBTOKEN};
is_deeply($grabbed->{settings}, $job_ref->{settings}, "settings correct");
ok(!$grabbed->{t_started}, "job start timestamp not present as job is not started");
is(scalar(@{$rjobs_before}) + 1,             scalar(@{$rjobs_after}), "number of running jobs");
is($rjobs_after->[-1]->{assigned_worker_id}, 1,                       'assigned worker set');

$grabbed = job_get($job->id);
is($grabbed->assigned_worker_id, $worker->{id}, 'worker assigned to job');
is($grabbed->worker->id,         $worker->{id}, 'job assigned to worker');
is($grabbed->state,              ASSIGNED,      'job is in assigned state');

# register worker again with no job while the web UI thinks it has an assigned job
is(register_worker, $id, 'worker re-registered');

# the assigned job is supposed to be re-scheduled
$grabbed = job_get($job->id);
is($grabbed->state,                     SCHEDULED, 'previous job has been re-scheduled');
is($grabbed->result,                    NONE,      'previous job has no result yet');
is($grabbed->settings_hash->{JOBTOKEN}, undef,     'the job token of the previous job has been cleared');

# register worker again with no job while the web UI thinks it as a running job
$grabbed->update({state => RUNNING});
$worker_db_obj->update({job_id => $grabbed->id});
$worker_db_obj->set_property(JOB_TOKEN => 'assume we have a token');
is(register_worker, $id, 'worker re-registered');

# the assigned job is supposed to be incompleted
$grabbed = job_get($job->id);
is($grabbed->state,                     DONE,       'previous job has is considered done');
is($grabbed->result,                    INCOMPLETE, 'previous job been incompleted');
is($grabbed->settings_hash->{JOBTOKEN}, undef,      'the job token of the previous job has been cleared');

OpenQA::Scheduler::Model::Jobs->singleton->schedule();
$grabbed = $sent->{$worker->{id}}->{job}->to_hash;
isnt($job->id, $grabbed->{id}, "new job grabbed") or die diag explain $grabbed;
isnt($grabbed->{settings}->{JOBTOKEN}, $job_ref->{settings}->{JOBTOKEN}, "job token differs")
  or die diag explain $grabbed->to_hash;

## update refs for isdeeply compare
$job_ref->{settings}->{JOBTOKEN} = $grabbed->{settings}->{JOBTOKEN};
$job_ref->{settings}->{NAME}     = $grabbed->{settings}->{NAME};

is_deeply($grabbed->{settings}, $job_ref->{settings}, "settings correct");
my $job3_id = $job->id;
my $job_id  = $grabbed->{id};

# Testing job_set_done
$job    = job_get($job_id);
$result = $job->done(result => 'passed');
is($result, 'passed', "job_set_done");
$job = job_get($job_id);
is($job->state,  "done",   "job_set_done changed state");
is($job->result, "passed", "job_set_done changed result");
ok($job->t_finished =~ /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, "job end timestamp updated");
ok(!$job->settings_hash->{JOBTOKEN},                          "job token not present after job done");

%args         = (result => "passed");
$current_jobs = list_jobs(%args);
is(scalar @{$current_jobs}, 1, "there is one passed job listed");

# we cannot test maxage here as it depends too much on too small
# time slots. The ui tests check maxage instead too
#%args = (maxage => 2);
#$current_jobs = list_jobs(%args);
#is_deeply($current_jobs, [$job], "list_jobs with finish in past");
#sleep 1;
#%args = (maxage => 1);
#$current_jobs = list_jobs(%args);
#is_deeply($current_jobs, [], "list_jobs with finish in future");

# Testing set_prio
$schema->resultset('Jobs')->find($job_id)->set_prio(100);
$job = job_get($job_id);
is($job->priority, 100, "job->set_prio");

$result = $schema->resultset('Jobs')->find($job_id)->delete;
my $no_job_id = job_get($job_id);
ok($result && !defined $no_job_id, "job_delete");

$job->discard_changes;

# Testing job_restart
# TBD

# Testing job_cancel
# TBD

# Testing job_fill_settings
# TBD

$result    = $schema->resultset('Jobs')->find($job2->id)->delete;
$no_job_id = job_get($job2->id);
ok($result && !defined $no_job_id, "job_delete");

$result    = $schema->resultset('Jobs')->find($job3_id)->delete;
$no_job_id = job_get($job3_id);
ok($result && !defined $no_job_id, "job_delete");


$current_jobs = list_jobs();
is_deeply($current_jobs, [], "no jobs listed");

my $asset = $schema->resultset('Assets')->register('iso', $settings{ISO});
is($asset->name, $settings{ISO}, "asset register returns same");

done_testing;
