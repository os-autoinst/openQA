#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Mojo::Base -signatures;
use Test::Mojo;
use Test::MockModule;
use Test::MockObject;
use OpenQA::Test::Case;
use OpenQA::Test::Client 'client';
use Test::Output qw(combined_like);

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 03-users.pl');
my $t = client(Test::Mojo->new('OpenQA::WebAPI'));
my $jobs = $t->app->schema->resultset('Jobs');

subtest 'Jobs should emit exactly one event' => sub {
    my @emitted_events;
    my $mock_emit = Test::MockObject->new();
    $mock_emit->mock(
        emit => sub ($self, $type, $args) {
            my (undef, undef, undef, $data) = @$args;
            push @emitted_events, {type => $type, data => $data};
        });
    # include the events emitted by OpenQA::Events->singleton->emit_event()
    $mock_emit->mock(
        # uncoverable subroutine
        emit_event => sub ($self, $type, %args) {    # uncoverable statement
            push @emitted_events, {type => $type, data => $args{data}};    # uncoverable statement
        });

    my $mock_events = Test::MockModule->new('OpenQA::Events');
    $mock_events->redefine(singleton => sub { return $mock_emit });
    my $scheduler_mock = Test::MockModule->new('OpenQA::Scheduler::Client');
    $scheduler_mock->redefine(wakeup => sub { });

    my %params = (TEST => 'event_test', DISTRI => 'foo', VERSION => 'bar', ARCH => 'baz');
    $t->post_ok('/api/v1/jobs', form => \%params)->status_is(200);
    my $job_id = $t->tx->res->json->{id};
    is(scalar @emitted_events, 1, 'exactly one event was emitted on create');
    is($emitted_events[0]->{data}{id}, $job_id, 'job_id is emitted on event');
    is($emitted_events[0]->{type}, 'openqa_job_create', 'data has correct event type');

    @emitted_events = ();
    combined_like { $t->post_ok('/api/v1/jobs/99926/restart?force=1')->status_is(200) } qr/Job 99926 duplicated/,
      'Job restarted successfully';
    is(scalar @emitted_events, 1, 'exactly one event was emitted on restart');
    is($emitted_events[0]->{data}{id}, 99926, 'job_id is emitted on event');
    is($emitted_events[0]->{type}, 'openqa_job_restart', 'data has correct event type');
};

done_testing;
