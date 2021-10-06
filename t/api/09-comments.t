# Copyright 2016-2020 SUSE LLC
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

use Test::Most;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '8';
use OpenQA::Test::Case;
use OpenQA::Test::Client 'client';
use OpenQA::Client;
use Mojo::IOLoop;

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 03-users.pl');
my $t = client(Test::Mojo->new('OpenQA::WebAPI'));

# create a parent group
$t->app->schema->resultset('JobGroupParents')->create({id => 1, name => 'Test parent', sort_order => 0});

sub test_get_comment {
    # Report failure at the callsite instead of the test function
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    my ($in, $id, $comment_id, $supposed_text) = @_;
    $t->get_ok("/api/v1/$in/$id/comments/$comment_id")->json_is('/id', $comment_id, 'comment id is correct')
      ->json_is('/text' => $supposed_text, 'comment text is correct');
}

sub test_get_comment_groups_json {
    my ($id, $supposed_text) = @_;
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

sub test_get_comment_invalid_job_or_group {
    my ($in, $id, $comment_id) = @_;
    $t->get_ok("/api/v1/$in/$id/comments/$comment_id")->status_is(404, 'comment not found');
    like(
        $t->tx->res->json->{error},
        qr/$id does not exist/,
        $in eq 'jobs' ? "Job $id does not exist" : "Job group $id does not exist"
    );
}

sub test_get_comment_invalid_comment {
    my ($in, $id, $comment_id) = @_;
    $t->get_ok("/api/v1/$in/$id/comments/$comment_id")->status_is(404, 'comment not found');
    is($t->tx->res->json->{error}, "Comment $comment_id does not exist", 'comment does not exist');
}

sub test_create_comment {
    my ($in, $id, $text) = @_;
    $t->post_ok("/api/v1/$in/$id/comments" => form => {text => $text})->status_is(200, 'comment can be created');
    return $t->tx->res->json->{id};
}

my $test_message         = 'This is a cool test ☠ - http://open.qa';
my $another_test_message = ' - this message will be\nappended if editing works ☠';
my $edited_test_message  = $test_message . $another_test_message;

sub test_comments {
    my ($in, $id) = @_;
    my $new_comment_id = test_create_comment($in, $id, $test_message);

    my %expected_names = (
        jobs          => 'Job',
        groups        => 'Job group',
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
        $t->get_ok("/api/v1/$in/$id/comments")->status_is(200)
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
        $t->put_ok("/api/v1/jobs/1234/comments/33546345" => form => {text => $edited_test_message})
          ->status_is(404, 'comment can not be deleted for invalid comment ID');
        test_get_comment_invalid_job_or_group('jobs', 1234, 35);
    };
};

subtest 'can not edit comment by other user' => sub {
    $t->put_ok("/api/v1/jobs/99981/comments/1" => form => {text => $edited_test_message . $another_test_message})
      ->status_is(403, 'editing comments by other users is forbidden');
    test_get_comment(jobs => 99981, 1, $edited_test_message);
};

subtest 'unauthorized users can only read' => sub {
    my $app = $t->app;
    $t->ua(OpenQA::Client->new()->ioloop(Mojo::IOLoop->singleton));
    $t->app($app);
    test_get_comment(jobs   => 99981, 1, $edited_test_message);
    test_get_comment(groups => 1001,  2, $edited_test_message);
};

done_testing();
