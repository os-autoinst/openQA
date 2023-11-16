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
use Test::Output 'combined_from';
use OpenQA::Jobs::Constants;
use OpenQA::Test::Case;
use OpenQA::Test::TimeLimit '10';
use OpenQA::Test::Utils qw(assume_all_assets_exist);
use Mojo::DOM;
use Mojo::JSON qw(decode_json);

my $test_case = OpenQA::Test::Case->new;
my $schema = $test_case->init_data(fixtures_glob => '01-jobs.pl 03-users.pl 05-job_modules.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');
my $jobs = $t->app->schema->resultset('Jobs');
my $auth = {'X-CSRF-Token' => $t->ua->get('/tests')->res->dom->at('meta[name=csrf-token]')->attr('content')};
$test_case->login($t, 'percival');
assume_all_assets_exist;

my $comment_must
  = Mojo::DOM->new(
'<span class="openqa-bugref" title="Bug referenced: bsc#1234"><a href="https://bugzilla.suse.com/show_bug.cgi?id=1234"><i class="test-label label_bug fa fa-bug"></i>&nbsp;bsc#1234</a></span>(Automatic carryover from <a href="/tests/99962">t#99962</a>)'
)->to_string;
my $carry_over_note = "\n(The hook script will not be executed.)";
sub comments ($url) {
    $t->get_ok("$url/comments_ajax")->status_is(200)->tx->res->dom->find('.media-comment > p')->map('content');
}

sub restart_with_result ($old_job, $result) {
    # this only works properly for passed tests, as the new test won't have any failed test modules listed
    # that would make it find a carryover candidate with matching test modules
    $t->post_ok("/api/v1/jobs/$old_job/restart", $auth)->status_is(200);
    my $res = decode_json($t->tx->res->body);
    my $new_job = $res->{result}[0]->{$old_job};
    $t->post_ok("/api/v1/jobs/$new_job/set_done", $auth => form => {result => $result})->status_is(200);
    return $res;
}

my $old_job = 99962;
my $job = 99963;

$schema->txn_begin;

subtest '"happy path": failed->failed carries over last issue reference' => sub {
    my $label = 'label:false_positive';
    my $second_label = 'bsc#1234';
    my $simple_comment = 'just another simple comment';
    for my $comment ($label, $second_label, $simple_comment) {
        $t->post_ok("/api/v1/jobs/$old_job/comments", $auth => form => {text => $comment})->status_is(200);
    }
    my @comments_previous = @{comments("/tests/$old_job")};
    is(scalar @comments_previous, 3, 'all entered comments found');
    like($comments_previous[0], qr/\Q$label/, 'comment present on previous test result');
    is($comments_previous[2], $simple_comment, 'another comment present');

    my $group = $t->app->schema->resultset('JobGroups')->find(1001);

    subtest 'carry over prevented via job group settings' => sub {
        $group->update({carry_over_bugrefs => 0});
        $t->post_ok("/api/v1/jobs/$job/set_done", $auth => form => {result => 'failed'})->status_is(200);
        is_deeply(comments("/tests/$job"), [], 'no bugrefs carried over');
    };

    subtest 'carry over enabled in job group settings, note about hook script' => sub {
        local $ENV{OPENQA_JOB_DONE_HOOK_FAILED} = 'foo';

        my $bugs = $t->app->schema->resultset('Bugs');
        $bugs->search({bugid => 'bsc#1234'})->delete; # ensure the bugref supposed to be inserted does not exist anyways
        $t->app->log->level('debug');
        $group->update({carry_over_bugrefs => 1});
        my $output = combined_from {
            $t->post_ok("/api/v1/jobs/$job/set_done", $auth => form => {result => 'failed'})->status_is(200);
        };
        $t->app->log->level('error');

        my @comments_current = @{comments("/tests/$job")};
        is(join('', @comments_current), $comment_must . $carry_over_note, 'only one bugref is carried over');
        like($comments_current[0], qr/\Q$second_label/, 'last entered bugref found, it is expanded');
        like $output, qr{\Q_carry_over_candidate($job): _failure_reason=amarok:none};
        like $output, qr{\Q_carry_over_candidate($job): checking take over from $old_job: _failure_reason=amarok:none};
        like $output, qr{\Q_carry_over_candidate($job): found a good candidate ($old_job)};
        ok $bugs->find({bugid => 'bsc#1234'}, {limit => 1}),
          'bugref inserted as part of comment contents being handled on carryover';
    };
};

subtest 'failed->passed discards all labels' => sub {
    my $res = restart_with_result($job, 'passed');
    my @comments_new = @{comments($res->{test_url}[0]->{$job})};
    is(scalar @comments_new, 0, 'no labels carried over to passed');
};

# Reset to a clean state
$schema->txn_rollback;
$schema->resultset('JobGroups')->find(1001)->update({carry_over_bugrefs => 1});
$schema->txn_begin;

subtest 'passed->failed does not carry over old labels' => sub {
    $t->post_ok("/api/v1/jobs/$old_job/comments", $auth => form => {text => 'bsc#1234'})->status_is(200);
    $t->post_ok("/api/v1/jobs/$old_job/set_done", $auth => form => {result => 'passed'})->status_is(200);
    $schema->resultset('JobModules')->search({job_id => $old_job})->update({result => PASSED});
    $t->post_ok("/api/v1/jobs/$job/set_done", $auth => form => {result => 'failed'})->status_is(200);
    my @comments_new = @{comments("/tests/$job")};
    is(scalar @comments_new, 0, 'no old labels on new failure');
};

# Reset to a clean state
$schema->txn_rollback;
$schema->txn_begin;

subtest 'failed->failed without labels does not fail' => sub {
    $t->post_ok("/api/v1/jobs/$job/set_done", $auth => form => {result => 'failed'})->status_is(200);
    my @comments_new = @{comments("/tests/$job")};
    is(scalar @comments_new, 0, 'nothing there, nothing appears');
};

subtest 'failed->failed labels which are not bugrefs are *not* carried over' => sub {
    $t->post_ok("/api/v1/jobs/$old_job/comments", $auth => form => {text => 'label:any_label'})->status_is(200);
    $t->post_ok("/api/v1/jobs/$job/set_done", $auth => form => {result => 'failed'})->status_is(200);
    my @comments_new = @{comments("/tests/$job")};
    is(join('', @comments_new), '', 'no simple labels are carried over');
    is(scalar @comments_new, 0, 'no simple label present in new result');
};

# Reset to a clean state
$schema->txn_rollback;
$schema->txn_begin;

subtest 'failed->failed flag:carryover comments are carried over' => sub {
    $t->post_ok("/api/v1/jobs/$old_job/comments", $auth => form => {text => 'flag:carryover'})->status_is(200);
    $t->post_ok("/api/v1/jobs/$job/set_done", $auth => form => {result => 'failed'})->status_is(200);
    my @comments_new = @{comments("/tests/$job")};
    like(join('', @comments_new), qr(flag:carryover), 'Comment with flag:carryover present in new job');
};

# Reset to a clean state
$schema->txn_rollback;

my ($prev_job, $curr_job) = map { $jobs->find($_) } (99962, 99963);

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
    $jobs->find(99962)->update_module('aplay', {result => 'fail', details => [{title => 'bsc#999888'}]});
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

subtest 'too many state changes' => sub {
    $t->app->config->{carry_over}->{state_changes_limit} = 1;
    my $mock = Test::MockModule->new('OpenQA::Schema::Result::Jobs');
    $mock->redefine(
        _failure_reason => sub ($self) {
            {99961 => 'a:failed', 99962 => 'b:failed', 99963 => 'c:failed'}->{$self->id};
        });
    $mock->redefine(
        _previous_scenario_jobs => sub ($self, $depth) {
            map { $jobs->find($_) } qw(99962 99961);
        });
    my $job = $jobs->find(99963);
    $t->app->log->level('debug');
    my $candidate;
    my $output = combined_from {
        $candidate = $job->_carry_over_candidate;
    };
    $t->app->log->level('error');
    is $candidate, undef, 'state_changes_limit reached, no candidate';
    like $output, qr{changed state more than 1 .2., aborting search}, 'debug output like expected';
};

done_testing;
