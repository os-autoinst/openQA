# Copyright 2016-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '8';
use OpenQA::Test::Case;
use OpenQA::Test::Client 'client';
use OpenQA::Jobs::Constants;
use OpenQA::Client;
use Mojo::IOLoop;

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 03-users.pl');
my $t = client(Test::Mojo->new('OpenQA::WebAPI'));
my $comments = $t->app->schema->resultset('Comments');

# create a parent group
$t->app->schema->resultset('JobGroupParents')->create({id => 1, name => 'Test parent', sort_order => 0});

sub test_get_comment ($in, $id, $comment_id, $supposed_text) {
    # Report failure at the callsite instead of the test function
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    $t->get_ok("/api/v1/$in/$id/comments/$comment_id")->json_is('/id', $comment_id, 'comment id is correct')
      ->json_is('/text' => $supposed_text, 'comment text is correct');
}

sub test_get_comment_groups_json ($id, $supposed_text) {
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    $t->get_ok("/group_overview/$id.json");
    my $found_comment = 0;
    for my $comment (@{$t->tx->res->json->{comments}}) {
        if ($comment->{text} eq $supposed_text) {
            $found_comment = 1;
            last;
        }
    }
    ok($found_comment, 'comment found in .json');
}

sub test_get_comment_invalid_job_or_group ($in, $id, $comment_id) {
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    $t->get_ok("/api/v1/$in/$id/comments/$comment_id")->status_is(404, 'comment not found');
    like(
        $t->tx->res->json->{error},
        qr/$id does not exist/,
        $in eq 'jobs' ? "Job $id does not exist" : "Job group $id does not exist"
    );
}

sub test_get_comment_invalid_comment ($in, $id, $comment_id) {
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    $t->get_ok("/api/v1/$in/$id/comments/$comment_id")->status_is(404, 'comment not found');
    is($t->tx->res->json->{error}, "Comment $comment_id does not exist", 'comment does not exist');
}

sub test_create_comment ($in, $id, $text) {
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    $t->post_ok("/api/v1/$in/$id/comments" => form => {text => $text})->status_is(200, 'comment can be created')
      ->or(sub { diag 'error: ' . $t->tx->res->json->{error} });
    return $t->tx->res->json->{id};
}

my $test_message = 'This is a cool test ☠ - http://open.qa';
my $another_test_message = ' - this message will be\nappended if editing works ☠';
my $edited_test_message = $test_message . $another_test_message;

sub test_comments ($in, $id) {
    my $new_comment_id = test_create_comment($in, $id, $test_message);

    my %expected_names = (
        jobs => 'Job',
        groups => 'Job group',
        parent_groups => 'Parent group',
    );
    my $expected_name = $expected_names{$in};

    subtest 'get comment' => sub {
        test_get_comment($in, $id, $new_comment_id, $test_message);
        test_get_comment_invalid_job_or_group($in, 1234, 35);
        test_get_comment_invalid_comment($in, $id, 123456);
    };

    subtest 'create comment without text' => sub {
        $t->post_ok("/api/v1/$in/$id/comments" => form => {})
          ->status_is(400, 'comment can not be created without text')
          ->json_is('/error' => 'Erroneous parameters (text missing)');
        $t->post_ok("/api/v1/$in/$id/comments" => form => {text => ''})
          ->status_is(400, 'comment can not be created with empty text')
          ->json_is('/error' => 'Erroneous parameters (text invalid)');
    };

    subtest 'create comment with invalid job or group' => sub {
        $t->post_ok("/api/v1/$in/1234/comments" => form => {text => $test_message})
          ->status_is(404, 'comment can not be created for invalid job/group')
          ->json_is('/error' => $expected_name . ' 1234 does not exist');
        test_get_comment_invalid_job_or_group($in, 1234, 35);
    };

    subtest 'update comment' => sub {
        $t->put_ok("/api/v1/$in/$id/comments/$new_comment_id" => form => {text => $edited_test_message})
          ->status_is(200, 'comment can be updated');
        test_get_comment($in, $id, $new_comment_id, $edited_test_message);
    };

    subtest 'update comment with invalid job or group' => sub {
        $t->put_ok("/api/v1/$in/1234/comments/$new_comment_id" => form => {text => $edited_test_message})
          ->status_is(404, 'comment can not be updated for invalid job/group')
          ->json_is('/error' => $expected_name . ' 1234 does not exist');
        test_get_comment_invalid_job_or_group('jobs', 1234, 35);
    };

    subtest 'update comment with invalid comment id' => sub {
        $t->put_ok("/api/v1/$in/$id/comments/33546345" => form => {text => $edited_test_message})
          ->status_is(404, 'comment can not be update for invalid comment ID');
        test_get_comment_invalid_job_or_group('jobs', 1234, 35);
    };

    subtest 'list multiple comments' => sub {
        $t->get_ok("/api/v1/$in/$id/comments?render_markdown=1")->status_is(200)
          ->json_is('/0/text' => $edited_test_message, 'text correct')->json_is(
            '/0/renderedMarkdown' =>
"<p>This is a cool test \x{2620} - <a href=\"http://open.qa\">http://open.qa</a> - this message will be\\nappended if editing works \x{2620}</p>\n",
            'markdown correct'
          );
        is(scalar @{$t->tx->res->json}, 1, 'one comment present');
    };

    subtest 'update comment without text' => sub {
        $t->put_ok("/api/v1/$in/$id/comments/$new_comment_id" => form => {})
          ->status_is(400, 'comment can not be updated without text')
          ->json_is('/error' => 'Erroneous parameters (text missing)');
        $t->put_ok("/api/v1/$in/$id/comments/$new_comment_id" => form => {text => ''})
          ->status_is(400, 'comment can not be updated with empty text')
          ->json_is('/error' => 'Erroneous parameters (text invalid)');
    };
    test_get_comment($in, $id, $new_comment_id, $edited_test_message);

    $t->delete_ok("/api/v1/$in/$id/comments/$new_comment_id")
      ->status_is(403, 'comment can not be deleted by unauthorized user');
}

subtest 'job comments' => sub {
    test_comments(jobs => 99981);
};

subtest 'group comments' => sub {
    test_comments(groups => 1001);
    test_get_comment_groups_json(1001, $edited_test_message);
};

subtest 'parent group comments' => sub {
    test_comments(parent_groups => 1);
};

subtest 'create many comments' => sub {
    $t->post_ok('/api/v1/comments?job_id=42&job_id=foo')->status_is(400);
    $t->json_is('/error' => 'Erroneous parameters (job_id invalid, text missing)');
    $t->post_ok('/api/v1/comments?job_id=42&job_id=80000&text=batch-comment')->status_is(400);
    $t->json_is('/error' => 'Not all comments could be created.', 'error returned');
    $t->json_is('/failed' => [{job_id => 42}], 'failed IDs returned');
    $t->json_is('/created' => [{job_id => 80000, id => 5}], 'created comment returned');
    ok my $comment = $comments->find(5), 'comment created' or return;
    is $comment->text, 'batch-comment', 'comment has expected text';
    $t->post_ok('/api/v1/comments?job_id=80000&text=batch-comment-2')->status_is(200);
};

subtest 'server-side limit has precedence over user-specified limit' => sub {
    $t->app->schema->txn_begin;

    for my $i (1 .. 9) {
        $t->post_ok('/api/v1/jobs/99981/comments' => form => {text => "comment number $i"})->status_is(200);
    }
    my $limits = OpenQA::App->singleton->config->{misc_limits};
    $limits->{generic_max_limit} = 5;
    $limits->{generic_default_limit} = 2;

    $t->get_ok('/api/v1/jobs/99981/comments?limit=10', 'query with exceeding user-specified limit for comments')
      ->status_is(200);
    my $jobs = $t->tx->res->json;
    explain $jobs;
    is ref $jobs, 'ARRAY', 'data returned (1)' and is scalar @$jobs, 5, 'maximum limit for comments is effective';

    $t->get_ok('/api/v1/jobs/99981/comments?limit=3', 'query with exceeding user-specified limit for comments')
      ->status_is(200);
    $jobs = $t->tx->res->json;
    is ref $jobs, 'ARRAY', 'data returned (2)' and is scalar @$jobs, 3, 'user limit for comments is effective';

    $t->get_ok('/api/v1/jobs/99981/comments', 'query with (low) default limit for comments')->status_is(200);
    $jobs = $t->tx->res->json;
    is ref $jobs, 'ARRAY', 'data returned (3)' and is scalar @$jobs, 2, 'default limit for comments is effective';

    $t->app->schema->txn_rollback;
};

subtest 'admin can delete comments' => sub {
    client($t, apikey => 'ARTHURKEY01', apisecret => 'EXCALIBUR');
    my $new_comment_id = test_create_comment(jobs => 99981, $test_message);
    $t->delete_ok("/api/v1/jobs/99981/comments/$new_comment_id")->status_is(200, 'comment can be deleted by admin');
    is($t->tx->res->json->{id}, $new_comment_id, 'deleted comment was the requested one');
    test_get_comment_invalid_comment(jobs => 99981, $new_comment_id);

    subtest 'delete comment with invalid job or group' => sub {
        $t->delete_ok("/api/v1/jobs/1234/comments/$new_comment_id")
          ->status_is(404, 'comment can be deleted for invalid job/group')
          ->json_is('/error' => 'Job 1234 does not exist');
        test_get_comment_invalid_job_or_group('jobs', 1234, 35);
    };

    subtest 'delete comment with invalid comment id' => sub {
        $t->put_ok('/api/v1/jobs/1234/comments/33546345' => form => {text => $edited_test_message})
          ->status_is(404, 'comment can not be deleted for invalid comment ID');
        test_get_comment_invalid_job_or_group('jobs', 1234, 35);
    };
};

$t->app->schema->txn_begin;

subtest 'delete many comments' => sub {
    $t->delete_ok('/api/v1/comments?id=42&id=foo')->status_is(400);
    $t->json_is('/error' => 'Erroneous parameters (id invalid)');
    $t->delete_ok('/api/v1/comments?id=5')->status_is(200, '200 returned if all comments deleted');
    $t->json_is('/deleted' => 1, 'one comment deleted');
    ok !$comments->find(5), 'comment is gone';
    $comments->create({id => 5, user_id => 1, text => 'foo label:force_result:softfailed'});
    $t->delete_ok('/api/v1/comments?id=5')->status_is(400, '400 returned if some comments preserved');
    $t->json_is('/deleted' => 0, 'no comments deleted');
    ok $comments->find(5), 'comment with "force_result"-label not deleted';
    $t->delete_ok('/api/v1/comments?id=98765&id=1&id=2')->status_is(400, '400 returned if some comments did not exist');
    $t->json_is('/deleted' => 2, 'two out of three comments deleted');
};

$t->app->schema->txn_rollback;

subtest 'can not edit comment by other user' => sub {
    $t->put_ok('/api/v1/jobs/99981/comments/1' => form => {text => $edited_test_message . $another_test_message})
      ->status_is(403, 'editing comments by other users is forbidden');
    test_get_comment(jobs => 99981, 1, $edited_test_message);
};

subtest 'can update job result with special label comment' => sub {
    my $job_id = 99938;
    my $schema = $t->app->schema;
    my $jobs = $schema->resultset('Jobs');
    my $events = $schema->resultset('AuditEvents');
    is $jobs->find($job_id)->result, 'failed', 'job initially is failed';
    is $events->all, 11, '11 events emitted so far';
    test_create_comment('jobs', $job_id, 'label:force_result:softfailed:simon_says');
    is $jobs->find($job_id)->result, 'softfailed', 'job is updated to softfailed';
    is $events->all, 13, 'events for result update emitted';
    ok $events->find({event => 'job_update_result'}), 'job_update_result event found';
    my $route = "/api/v1/jobs/$job_id/comments";
    my $comments = $schema->resultset('Comments');
    my $nr_comments = $comments->all;
    $t->post_ok($route => form => {text => 'label:force_result:invalid_result'})
      ->status_is(400, 'comment can not be created with invalid result for force_result')
      ->json_like('/error' => qr/Invalid result/);
    is $jobs->find($job_id)->result, 'softfailed', 'job is not updated with invalid result';
    is $comments->all, $nr_comments, 'no new comment created with invalid result';
    my $global_cfg = $t->app->config->{global};
    $global_cfg->{force_result_regex} = '[A-Z0-9-]+';
    $t->post_ok($route => form => {text => 'label:force_result:passed'})
      ->status_is(400, 'comment can not be created when description pattern does not match')
      ->json_like('/error' => qr/description.*does not match/);
    is $jobs->find($job_id)->result, 'softfailed', 'job is not updated when description pattern does not match';
    is $comments->all, $nr_comments, 'no new comment created for wrong description';
    test_create_comment('jobs', $job_id, 'label:force_result:passed:boo42');
    is $jobs->find($job_id)->result, 'passed', 'job is updated when description pattern matches';
    my $id = $t->get_ok("/api/v1/jobs/$job_id/comments")->tx->res->json->[0]->{id};
    $t->put_ok("$route/$id" => form => {text => 'label:force_result:passed'})
      ->status_is(400, 'can not update comment with invalid description')
      ->json_like('/error' => qr/description.*does not match/);
    $t->delete_ok("$route/$id")->status_is(403, 'can not delete comment with label:force_result');
    $t->put_ok("$route/$id" => form => {text => 'no label'})->status_is(200, 'can update comment with special label');
    $t->delete_ok("$route/$id")->status_is(200, 'can now delete comment with former label');
    $global_cfg->{force_result_regex} = '';
    $job_id = 99927;
    $route = "/api/v1/jobs/$job_id/comments";
    is $jobs->find($job_id)->state, 'scheduled', 'job initially is unfinished';
    $t->post_ok($route => form => {text => 'label:force_result:passed'})
      ->status_is(400, 'comment can not be created when job is unfinished')
      ->json_like('/error' => qr/only allowed on finished/);
    is $jobs->find($job_id)->result, 'none', 'unfinished job will not be updated';
    $job_id = 99981;
    $route = "/api/v1/jobs/$job_id/comments";
    is $jobs->find($job_id)->state, CANCELLED, 'job initially is cancelled';
    $t->post_ok($route => form => {text => 'label:force_result:passed:foo'})
      ->status_is(200, 'comment can be created when job is cancelled');
    my $job = $jobs->find($job_id);
    is $job->state, DONE, 'cancelled job is now considered done';
    is $job->result, PASSED, 'result of cancelled job has been updated';
};

subtest 'unauthorized users can only read' => sub {
    my $app = $t->app;
    $t->ua(OpenQA::Client->new()->ioloop(Mojo::IOLoop->singleton));
    $t->app($app);
    test_get_comment(jobs => 99981, 1, $edited_test_message);
    test_get_comment(groups => 1001, 2, $edited_test_message);
    $t->post_ok('/api/v1/comments?job_id=80000&text=batch-comment')->status_is(403);
    $t->delete_ok('/api/v1/comments?id=1')->status_is(403);
    ok $comments->find(1), 'comment still exists';
};

done_testing();
