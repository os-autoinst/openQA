#!/usr/bin/env perl

# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use Mojo::File 'path';
use OpenQA::Test::Case;
use OpenQA::Jobs::Constants;
use OpenQA::Test::TimeLimit '6';
use OpenQA::Scheduler::Model::Jobs;
use OpenQA::Test::FakeWebSocketTransaction;
use OpenQA::WebSockets::Client;
use OpenQA::Test::Utils 'embed_server_for_testing';
use OpenQA::WorkerReservation 'RESERVATION_PROPERTIES';
use Mojo::Util 'scope_guard';
use Time::Seconds;

embed_server_for_testing(
    server_name => 'OpenQA::WebSockets',
    client => OpenQA::WebSockets::Client->singleton,
);


# init test case
my $test_case = OpenQA::Test::Case->new;
$test_case->init_data(fixtures_glob => '01-jobs.pl 02-workers.pl 03-users.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');

# get resultsets
my $db = $t->app->schema;
my $workers = $db->resultset('Workers');
my $jobs = $db->resultset('Jobs');

$db->txn_begin;

subtest 'reschedule assigned jobs' => sub {
    my $worker_1 = $workers->find({host => 'localhost', instance => 1});

    # assume the jobs 99961, 99963 and 99937 are assigned to the worker and 99961 is the current job
    $workers->search({})->update({job_id => undef});
    $worker_1->update({job_id => 99961});
    $jobs->find($_)->update({state => ASSIGNED, assigned_worker_id => $worker_1->id}) for (99961, 99963);
    $jobs->find(99937)->update({state => PASSED, assigned_worker_id => $worker_1->id});

    $worker_1->reschedule_assigned_jobs;
    $worker_1->discard_changes;

    is $worker_1->job_id, undef, 'current job has been un-assigned';
    for my $job_id ((99961, 99963)) {
        my $job = $jobs->find($job_id);
        is $job->state, SCHEDULED, "job $job_id is scheduled again";
        is $job->assigned_worker_id, undef, "job $job_id has no worker assigned anymore";
    }
    my $passed_job = $jobs->find(99937);
    is $passed_job->state, PASSED, 'passed job not affected';
    is $passed_job->assigned_worker_id, $worker_1->id, 'passed job still associated with worker';
};

$db->txn_rollback;

subtest 'delete job which is currently assigned to worker' => sub {
    my $worker_1 = $workers->find({host => 'localhost', instance => 1});
    my $job_of_worker_1 = $worker_1->job;
    is $job_of_worker_1->id, 99963, 'job 99963 belongs to worker 1 as specified in fixtures';

    $job_of_worker_1->delete;

    $worker_1 = $workers->find({host => 'localhost', instance => 1});
    ok $worker_1, 'worker 1 still exists'
      and is $worker_1->job, undef, 'job has been unassigned';
};

subtest 'delete job from worker history' => sub {
    my $worker_1 = $workers->find({host => 'localhost', instance => 1});
    my $job = $jobs->find(99926);
    $job->update({assigned_worker_id => $worker_1->id});
    is_deeply [map { $_->id } $worker_1->previous_jobs->all], [99926], 'previous job assigned';

    $job->delete;
    $worker_1 = $workers->find({host => 'localhost', instance => 1});
    ok $worker_1, 'worker 1 still exists'
      and is_deeply [map { $_->id } $worker_1->previous_jobs->all], [], 'previous jobs empty again';
};

subtest 'tmpdir handling when preparing worker for job' => sub {
    my ($job, $worker) = ($jobs->find(99937), $workers->find({host => 'localhost', instance => 1}));
    my $tmpdir = $worker->get_property('WORKER_TMPDIR');
    ok !$tmpdir, 'no tmpdir assigned so far';

    $job->prepare_for_work($worker);
    $worker->discard_changes;
    ok -d ($tmpdir = $worker->get_property('WORKER_TMPDIR')), 'tmpdir created and assigned';
    $job->prepare_for_work($worker);
    $worker->discard_changes;
    ok !-d $tmpdir, 'previous tmpdir removed';
    path($worker->get_property('WORKER_TMPDIR'))->remove_tree;
};

subtest 'tmpdir handling when assigning multiple jobs to a worker' => sub {
    my $worker = $workers->first;
    my $worker_id = $worker->id;
    my @job_ids = (99926, 99927, 99928);
    my @jobs = $jobs->search({id => {-in => \@job_ids}})->all;
    my @job_sequence = (99927, [99928, 99926]);

    # use fake web socket connection
    my $fake_ws_tx = OpenQA::Test::FakeWebSocketTransaction->new;
    my $sent_messages = $fake_ws_tx->sent_messages;
    OpenQA::WebSockets::Model::Status->singleton->workers->{$worker_id}->{tx} = $fake_ws_tx;
    my $tmpdir = $worker->get_property('WORKER_TMPDIR');
    ok !$tmpdir, 'no tmpdir assigned so far';

    OpenQA::Scheduler::Model::Jobs->new->_assign_multiple_jobs_to_worker(\@jobs, $worker, \@job_sequence, \@job_ids);
    $worker->discard_changes;
    ok -d ($tmpdir = $worker->get_property('WORKER_TMPDIR')), 'tmpdir created and assigned';
    OpenQA::Scheduler::Model::Jobs->new->_assign_multiple_jobs_to_worker(\@jobs, $worker, \@job_sequence, \@job_ids);
    $worker->discard_changes;
    ok !-d $tmpdir, 'previous tmpdir removed';
    path($worker->get_property('WORKER_TMPDIR'))->remove_tree;
};

subtest 'VNC argument' => sub {
    my $worker = $workers->first;
    $worker->set_property(WORKER_HOSTNAME => '');
    is $worker->vnc_argument, 'remotehost:5991', 'host:instance returned';
    $worker->set_property(WORKER_HOSTNAME => 'remotehost.foo.bar');
    is $worker->vnc_argument, 'remotehost.foo.bar:5991', 'WORKER_HOSTNAME used if set';
};

subtest 'worker reservation model' => sub {
    my $worker = $workers->first;
    $worker->delete_properties([RESERVATION_PROPERTIES]);
    $worker->update({job_id => undef, error => undef, t_seen => DateTime->now(time_zone => 'UTC')});

    my $users = $db->resultset('Users');
    my ($admin, $non_operator, $operator) = map { $users->find($_) } 99901, 99902, 99903;
    my $other_operator = $users->create({username => 'galahad', is_operator => 1, feature_version => 0});

    my @rejected = (
        [[$non_operator, 'valid comment', '1h'], qr/Insufficient permissions/, 'non-operator users'],
        [[$operator, ' ', '1h'], qr/comment is required/, 'a blank comment'],
        [[$operator, undef, '1h'], qr/comment is required/, 'a missing comment'],
        [[$operator, 'valid comment', 'soon'], qr/Invalid duration format 'soon'/, 'an unparsable duration'],
        [[$operator, 'valid comment', '10d'], qr/exceeds the maximum of 432000s/, 'a duration beyond the operator max'],
        [[$operator, 'valid comment', '0'], qr/only allowed for admins/, 'an indefinite duration as operator'],
    );
    throws_ok { $worker->reserve(@{$_->[0]}) } $_->[1], "refuse reservation with $_->[2]" for @rejected;
    ok !$worker->is_reserved, 'worker is not reserved after all rejected attempts';
    is $worker->reservation, undef, 'unreserved worker reports no reservation';

    $worker->reserve($operator, 'operator reservation', '2h');
    ok $worker->is_reserved, 'worker is considered reserved after a successful reserve call';
    is $worker->status, 'reserved', 'worker status reports reserved while the reservation is active';
    is $worker->reservation->{user}, $operator->username, 'reservation names the reserving operator';
    is $worker->reservation->{comment}, 'operator reservation', 'reservation comment matches what was passed';
    like $worker->reservation->{t_created}, qr/^\d{4}(-\d\d){2}T(\d\d:){2}\d\dZ$/, 'reserved at ISO 8601 timestamp';
    is $workers->stats->{reserved_workers}, 1, 'statistics count exactly one reserved worker';
    is_deeply [keys %{$workers->reserved_worker_ids}], [$worker->id], 'bulk lookup reports the reserved worker';
    ok !exists $worker->info->{properties}->{RESERVED_BY_ID}, 'raw reservation properties are not exposed via info';

    my @precedence = (['running', job_id => 99937], ['broken', error => 'some error'], ['dead', t_seen => undef]);
    for my $case (@precedence) {
        my ($expected, $column, $value) = @$case;
        my $original = $worker->get_column($column);
        $worker->update({$column => $value});
        is $worker->discard_changes->status, $expected, "$expected state takes precedence over the reservation";
        $worker->update({$column => $original});
        $worker->discard_changes;
    }

    throws_ok { $worker->reserve($other_operator, 'other reservation', '1h') }
    qr/already reserved by percival/, 'refuse overlapping reservations and name the current owner';
    throws_ok { $worker->reserve($admin, 'admin without force', '1h') }
    qr/already reserved/, 'refuse admin reservations on reserved workers unless forced';

    $worker->reserve($admin, 'admin override reservation', '3h', 1);
    is $worker->reservation->{user}, $admin->username, 'admin force override changes the reservation owner';
    is $worker->reservation->{comment}, 'admin override reservation', 'admin force override updates the comment';

    throws_ok { $worker->release($other_operator) }
    qr/Insufficient permissions/, 'refuse release attempts by users other than the owner or an admin';
    $worker->release($admin);
    ok !$worker->is_reserved, 'worker is no longer reserved after release';
    is $worker->status, 'idle', 'released worker status goes back to idle';
    throws_ok { $worker->release($admin) } qr/not reserved/, 'refuse releasing a worker without reservation';

    $worker->reserve($operator, 'expiring reservation', '1h');
    $worker->set_property(RESERVED_T_EXPIRES => time - 1);
    ok !$worker->is_reserved, 'reservation is inactive once the expiry has passed';
    is $worker->status, 'idle', 'expired reservation status goes back to idle';
    is $worker->reservation, undef, 'expired reservation is not reported despite left over properties';
    is_deeply $workers->reserved_worker_ids, {}, 'bulk lookup ignores expired reservations';

    $worker->reserve($admin, 'indefinite reservation', '0');
    ok $worker->is_reserved, 'a duration of 0 reserves the worker indefinitely';
    is $worker->reservation->{t_expires}, undef, 'indefinite reservation has no expiry timestamp';

    $worker->set_property(RESERVED_BY_ID => 999999);
    is $worker->reservation->{user}, 'unknown', 'reservation of a no longer existing user is reported as unknown';
    $worker->delete_properties([RESERVATION_PROPERTIES]);
};

subtest 'unlimited admin reservations are capped once admin_max_duration is configured' => sub {
    my $config = $t->app->config->{worker_reservation};
    my $guard = scope_guard sub { $config->{admin_max_duration} = 0 };
    $config->{admin_max_duration} = ONE_HOUR;
    my $worker = $workers->first;
    my $admin = $db->resultset('Users')->find(99901);
    throws_ok { $worker->reserve($admin, 'too long for an admin', '2h') }
    qr/exceeds the maximum of 3600s/, 'admins are limited as well once a maximum is configured';
    ok !$worker->is_reserved, 'worker stays unreserved when the admin duration is rejected';
};

done_testing();
