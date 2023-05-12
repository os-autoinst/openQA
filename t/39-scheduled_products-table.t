#!/usr/bin/env perl
# Copyright 2019-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use Test::MockModule;
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::ScheduledProducts qw(ADDED SCHEDULED SCHEDULING CANCELLING CANCELLED);
use OpenQA::Test::TimeLimit '6';
use OpenQA::Test::Case;
use OpenQA::Utils;

OpenQA::Test::Case->new->init_data;
my $t = Test::Mojo->new('OpenQA::WebAPI');

my $schema = $t->app->schema;
my $scheduled_products = $schema->resultset('ScheduledProducts');
my $users = $schema->resultset('Users');
my $user = $users->create_user('foo');
my %settings = (
    distri => 'openSUSE',
    version => '15.1',
    flavor => 'DVD',
    arch => 'x86_64',
    build => 'foo',
    settings => {some => 'settings'},
    user_id => $user->id,
);

# prevent job creation
my $scheduled_products_mock = Test::MockModule->new('OpenQA::Schema::Result::ScheduledProducts');
$scheduled_products_mock->redefine(_generate_jobs => sub { return undef; });

my $scheduled_product;
subtest 'handling assets with invalid name' => sub {
    $scheduled_product = $scheduled_products->create(\%settings);

    $schema->txn_begin;
    is_deeply(
        $scheduled_product->schedule_iso({REPO_0 => ''}),
        {error => 'Asset type and name must not be empty.'},
        'schedule_iso prevents adding assets with empty name',
    );
    $schema->txn_rollback;

    like $scheduled_product->schedule_iso({_DEPRIORITIZEBUILD => 1, TEST => 'foo'})->{error},
      qr/One must not specify TEST and _DEPRIORITIZEBUILD.*/,
      'schedule_iso prevents deprioritization/obsoletion when scheduling single scenario';

    $scheduled_product->discard_changes;
    is $scheduled_product->status, SCHEDULED, 'product marked as scheduled, though';

    $scheduled_product = $scheduled_products->create(\%settings);
    is_deeply(
        $scheduled_product->schedule_iso({REPO_0 => 'invalid'}),
        {
            successful_job_ids => [],
            failed_job_info => [],
        },
        'schedule_iso allows non-existent assets though',
    );

    $scheduled_product->discard_changes;
    is $scheduled_product->status, SCHEDULED, 'product marked as scheduled, though';
};

is $scheduled_product->schedule_iso(\%settings), undef, 'scheduling the same product again prevented';

my $test_job = $scheduled_product->jobs->create({TEST => 'testjob'});
subtest 'cancellation after product has been scheduled' => sub {
    is $scheduled_product->cancel('test reason 1'), 1, 'cancel returns the number of affected jobs';
    $scheduled_product->discard_changes;
    $test_job->discard_changes;
    is $scheduled_product->status, CANCELLED, 'scheduled product has been cancelled';
    is $test_job->state, CANCELLED, 'test job has been cancelled';
    is $test_job->result, USER_CANCELLED, 'test job treated as cancelled by the user';
    is $test_job->reason, 'scheduled product cancelled: test reason 1', 'cancellation reason assigned to test job';
};

subtest 'cancellation while product is still scheduling' => sub {
    # trigger cancellation when the scheduled product is still scheduling jobs
    $scheduled_product->update({status => SCHEDULING});
    $test_job->update({state => SCHEDULED, result => NONE});
    $scheduled_product->cancel('test reason 2');
    $scheduled_product->discard_changes;
    $test_job->discard_changes;
    is $scheduled_product->status, CANCELLING, 'scheduled product is cancelling';
    is $test_job->state, SCHEDULED, 'test job still scheduled';

    # assume scheduling jobs has been concluded
    $scheduled_product->set_done({the => 'result'});
    $scheduled_product->discard_changes;
    $test_job->discard_changes;
    is $scheduled_product->status, CANCELLED, 'scheduled product has been cancelled';
    is $test_job->state, CANCELLED, 'test job has been cancelled';
    is $test_job->result, USER_CANCELLED, 'test job treated as cancelled by the user';
    is $test_job->reason, 'scheduled product cancelled: test reason 2', 'cancellation reason assigned to test job';
};

done_testing();
