#!/usr/bin/env perl

# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;
use OpenQA::Events;
use OpenQA::Jobs::Constants;
use Test::Mojo;
use Test::Warnings ':report_warnings';
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '30';
use OpenQA::Test::Case;

my $schema = OpenQA::Test::Case->new->init_data(skip_schema => 1);
my $t = Test::Mojo->new('OpenQA::WebAPI');

my %settings = (
    DISTRI => 'Unicorn',
    FLAVOR => 'pink',
    VERSION => '42',
    ARCH => 'x86_64',
);

sub _job_create (@args) { $schema->resultset('Jobs')->create_from_settings(@args) }

sub job_is_linked ($job) {
    $job->discard_changes;
    $job->comments->find({text => {like => 'label:linked%'}}) ? 1 : 0;
}

subtest 'job is marked as linked if accessed from recognized referal' => sub {
    my $test_referer = 'http://test.referer.info/foobar/123';
    $t->app->config->{global}->{recognized_referers}
      = ['test.referer.info', 'test.referer1.info', 'test.referer2.info', 'test.referer3.info'];
    my %_settings = %settings;
    my $openqa_events = OpenQA::Events->singleton;
    my @comment_events;
    my $cb = $openqa_events->on(openqa_comment_create => sub ($events, $data) { push @comment_events, $data });
    $_settings{TEST} = 'refJobTest';
    my $job = _job_create(\%_settings);
    is job_is_linked($job), 0, 'new job is not linked';
    $t->get_ok('/tests/' . $job->id => {Referer => $test_referer})->status_is(200);
    is job_is_linked($job), 1, 'job linked after accessed from known referer';
    is scalar @comment_events, 1, 'exactly one comment event emitted' or always_explain \@comment_events;
    $openqa_events->unsubscribe($cb);

    $_settings{TEST} = 'refJobTest-step';
    $job = _job_create(\%_settings);

    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {}});
    my $module = $job->modules->find({name => 'a'});
    $job->update;
    is job_is_linked($job), 0, 'new job is not linked';
    $t->get_ok('/tests/' . $job->id . '/modules/' . $module->id . '/steps/1' => {Referer => $test_referer})
      ->status_is(302);
    is job_is_linked($job), 1, 'job linked after accessed from known referer';

    subtest 'do not link not existing tickets from recognized referal' => sub {
        $test_referer = 'http://test.referer.info/foobar/new';
        my $job = _job_create(\%_settings);
        is job_is_linked($job), 0, 'new job is not linked';
        $t->get_ok('/tests/' . $job->id => {Referer => $test_referer})->status_is(200);
        is job_is_linked($job), 0, 'job is not linked from known referer without an issue_id';
    };
};

subtest 'job is not marked as linked if accessed from unrecognized referal' => sub {
    $t->app->config->{global}->{recognized_referers}
      = ['test.referer.info', 'test.referer1.info', 'test.referer2.info', 'test.referer3.info'];
    my %_settings = %settings;
    $_settings{TEST} = 'refJobTest2';
    my $job = _job_create(\%_settings);
    is job_is_linked($job), 0, 'new job is not linked';
    $t->get_ok('/tests/' . $job->id => {Referer => 'http://unknown.referer.info'})->status_is(200);
    is job_is_linked($job), 0, 'job not linked after accessed from unknown referer';
    $t->get_ok('/tests/' . $job->id => {Referer => 'http://test.referer.info/'})->status_is(200);
    is job_is_linked($job), 0, 'job not linked after accessed from referer with empty query_path';
};

done_testing;
