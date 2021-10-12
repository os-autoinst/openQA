#!/usr/bin/env perl

# Copyright 2016-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Mojo::Base -signatures;
use Test::MockModule;
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::Case;
use OpenQA::Test::TimeLimit '10';
use OpenQA::Test::Utils qw(assume_all_assets_exist);
use Mojo::JSON qw(decode_json);

my $test_case = OpenQA::Test::Case->new;
my $schema = $test_case->init_data(fixtures_glob => '01-jobs.pl 03-users.pl 05-job_modules.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');
my $rs = $t->app->schema->resultset('Jobs');
my $auth = {'X-CSRF-Token' => $t->ua->get('/tests')->res->dom->at('meta[name=csrf-token]')->attr('content')};
$test_case->login($t, 'percival');
assume_all_assets_exist;

my $comment_must
  = '<a href="https://bugzilla.suse.com/show_bug.cgi?id=1234">bsc#1234</a>(Automatic takeover from <a href="/tests/99962">t#99962</a>)';
sub comments ($url) {
    $t->get_ok("$url/comments_ajax")->status_is(200)->tx->res->dom->find('.media-comment > p')->map('content');
}

sub restart_with_result ($old_job, $result) {
    $t->post_ok("/api/v1/jobs/$old_job/restart", $auth)->status_is(200);
    my $res = decode_json($t->tx->res->body);
    my $new_job = $res->{result}[0]->{$old_job};
    $t->post_ok("/api/v1/jobs/$new_job/set_done", $auth => form => {result => $result})->status_is(200);
    return $res;
}

$schema->txn_begin;

subtest '"happy path": failed->failed carries over last issue reference' => sub {
    my $label = 'label:false_positive';
    my $second_label = 'bsc#1234';
    my $simple_comment = 'just another simple comment';
    for my $comment ($label, $second_label, $simple_comment) {
        $t->post_ok('/api/v1/jobs/99962/comments', $auth => form => {text => $comment})->status_is(200);
    }
    my @comments_previous = @{comments('/tests/99962')};
    is(scalar @comments_previous, 3, 'all entered comments found');
    is($comments_previous[0], $label, 'comment present on previous test result');
    is($comments_previous[2], $simple_comment, 'another comment present');

    my $group = $t->app->schema->resultset('JobGroups')->find(1001);

    subtest 'carry over prevented via job group settings' => sub {
        $group->update({carry_over_bugrefs => 0});
        $t->post_ok('/api/v1/jobs/99963/set_done', $auth => form => {result => 'failed'})->status_is(200);
        is_deeply(comments('/tests/99963'), [], 'no bugrefs carried over');
    };

    subtest 'carry over enabled in job group settings' => sub {
        $group->update({carry_over_bugrefs => 1});
        $t->post_ok('/api/v1/jobs/99963/set_done', $auth => form => {result => 'failed'})->status_is(200);

        my @comments_current = @{comments('/tests/99963')};
        is(join('', @comments_current), $comment_must, 'only one bugref is carried over');
        like($comments_current[0], qr/\Q$second_label/, 'last entered bugref found, it is expanded');
    };
};

my ($job, $old_job);

subtest 'failed->passed discards all labels' => sub {
    my $res = restart_with_result(99963, 'passed');
    $job = $res->{result}[0]->{99963};
    my @comments_new = @{comments($res->{test_url}[0]->{99963})};
    is(scalar @comments_new, 0, 'no labels carried over to passed');
};

subtest 'passed->failed does not carry over old labels' => sub {
    my $res = restart_with_result($job, 'failed');
    $old_job = $job;
    $job = $res->{result}[0]->{$job};
    my @comments_new = @{comments($res->{test_url}[0]->{$old_job})};
    is(scalar @comments_new, 0, 'no old labels on new failure');
};

subtest 'failed->failed without labels does not fail' => sub {
    my $res = restart_with_result($job, 'failed');
    $old_job = $job;
    $job = $res->{result}[0]->{$job};
    my @comments_new = @{comments($res->{test_url}[0]->{$old_job})};
    is(scalar @comments_new, 0, 'nothing there, nothing appears');
};

subtest 'failed->failed labels which are not bugrefs are *not* carried over' => sub {
    my $label = 'label:any_label';
    $t->post_ok("/api/v1/jobs/$job/comments", $auth => form => {text => $label})->status_is(200);
    my $res = restart_with_result($job, 'failed');
    $old_job = $job;
    my @comments_new = @{comments($res->{test_url}[0]->{$old_job})};
    is(join('', @comments_new), '', 'no simple labels are carried over');
    is(scalar @comments_new, 0, 'no simple label present in new result');
};

# Reset to a clean state
$schema->txn_rollback;

my ($prev_job, $curr_job) = map { $rs->find($_) } (99962, 99963);

subtest 'failed in different modules *without* bugref in details' => sub {
    $t->post_ok('/api/v1/jobs/99962/comments', $auth => form => {text => 'bsc#1234'})->status_is(200);
    # Add details for the failure
    $prev_job->update_module('aplay', {result => 'fail', details => [{title => 'not a bug reference'}]});
    # Fail second module, so carry over is not triggered due to the failure in the same module
    $curr_job->update_module('yast2_lan', {result => 'fail', details => [{title => 'not a bug reference'}]});
    $t->post_ok('/api/v1/jobs/99963/set_done', $auth => form => {result => 'failed'})->status_is(200);
    is @{comments('/tests/99963')}, 0,
      'no carry-over when not bug reference is used and job fails on different modules';
};

subtest 'failed in different modules with different bugref in details' => sub {
    # Fail test in different modules with different bug references
    $rs->find(99962)->update_module('aplay', {result => 'fail', details => [{title => 'bsc#999888'}]});
    $curr_job->update_module('yast2_lan', {result => 'fail', details => [{title => 'bsc#77777'}]});
    $t->post_ok('/api/v1/jobs/99963/set_done', $auth => form => {result => 'failed'})->status_is(200);
    is scalar @{comments('/tests/99963')}, 0,
      'no carry-over when bug references differ and jobs fail on different modules';
};

subtest 'failed in different modules with same bugref in details' => sub {
    # Fail test in different modules with same bug reference and a 3rd module
    $prev_job->update_module('aplay', {result => 'fail', details => [{title => 'bsc#77777'}]});
    $curr_job->update_module('yast2_lan', {result => 'fail', details => [{title => 'bsc#77777'}]});
    $curr_job->update_module('bootloader', {result => 'softfail'});
    $t->post_ok('/api/v1/jobs/99963/set_done', $auth => form => {result => 'failed'})->status_is(200);
    is @{comments('/tests/99963')}, 0,
      'no carry-over when 3rd module fails, despite a matching bugref between other modules';

    # Remove failure in 3rd module
    $curr_job->update_module('bootloader', {result => 'passed'});
    $t->post_ok('/api/v1/jobs/99963/set_done', $auth => form => {result => 'failed'})->status_is(200);
    is join('', @{comments('/tests/99963')}), $comment_must, 'label is carried over without other failing modules';
};

subtest 'failure reason still computed without results, modules without results taken into account' => sub {
    my $mock = Test::MockModule->new('OpenQA::Schema::Result::JobModules');
    $mock->redefine(results => undef);
    like $curr_job->_failure_reason, qr/amarok:none,aplay:failed,.*yast2_lan:failed,.*zypper_up:none/, 'failure reason';
};

done_testing;
