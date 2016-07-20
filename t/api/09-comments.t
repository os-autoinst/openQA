# Copyright (C) 2016 SUSE LLC
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

BEGIN {
    unshift @INC, 'lib';
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;
use OpenQA::Client;
use Mojo::IOLoop;

OpenQA::Test::Case->new->init_data;

my $t = Test::Mojo->new('OpenQA::WebAPI');

# XXX: Test::Mojo loses it's app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

sub test_get_comment {
    my ($in, $id, $comment_id, $supposed_text) = @_;
    my $get = $t->get_ok("/api/v1/$in/$id/comments/$comment_id");
    is($get->tx->res->json->{text}, $supposed_text, 'comment text is correct');
}

sub test_get_comment_invalid_job_or_group {
    my ($in, $id, $comment_id) = @_;
    my $get = $t->get_ok("/api/v1/$in/$id/comments/$comment_id")->status_is(404, 'comment not found');
    like($get->tx->res->json->{error}, qr/$id does not exist/, $in eq 'jobs' ? "Job $id does not exist" : "Job group $id does not exist");
}

sub test_get_comment_invalid_comment {
    my ($in, $id, $comment_id) = @_;
    my $get = $t->get_ok("/api/v1/$in/$id/comments/$comment_id")->status_is(404, 'comment not found');
    is($get->tx->res->json->{error}, "Comment $comment_id does not exist", 'comment does not exist');
}

sub test_create_comment {
    my ($in, $id, $text) = @_;
    my $post = $t->post_ok("/api/v1/$in/$id/comments" => form => {text => $text})->status_is(200, 'comment can be created');
    return $post->tx->res->json->{id};
}

my $test_message         = 'This is a cool test ☠';
my $another_test_message = ' - this message will be\nappended if editing works ☠';
my $edited_test_message  = $test_message . $another_test_message;

sub test_comments {
    my ($in, $id) = @_;
    my $new_comment_id = test_create_comment($in, $id, $test_message);

    subtest 'get comment' => sub {
        test_get_comment($in, $id, $new_comment_id, $test_message);
        test_get_comment_invalid_job_or_group($in, 1234, 35);
        test_get_comment_invalid_comment($in, $id, 123456);
    };

    subtest 'create comment without text' => sub {
        my $post = $t->post_ok("/api/v1/$in/$id/comments" => form => {text => ''})->status_is(400, 'comment can not be created without text');
        is($post->tx->res->json->{error}, 'No/invalid text specified');
    };

    subtest 'create comment with invalid job or group' => sub {
        my $post = $t->post_ok("/api/v1/$in/1234/comments" => form => {text => $test_message})->status_is(404, 'comment can not be created for invalid job/group');
        is($post->tx->res->json->{error}, $in eq 'jobs' ? 'Job 1234 does not exist' : 'Job group 1234 does not exist');
        test_get_comment_invalid_job_or_group($in, 1234, 35);
    };

    subtest 'update comment' => sub {
        my $put = $t->put_ok("/api/v1/$in/$id/comments/$new_comment_id" => form => {text => $edited_test_message})->status_is(200, 'comment can be updated');
        test_get_comment($in, $id, $new_comment_id, $edited_test_message);
    };

    subtest 'update comment with invalid job or group' => sub {
        my $put = $t->put_ok("/api/v1/$in/1234/comments/$new_comment_id" => form => {text => $edited_test_message})->status_is(404, 'comment can not be updated for invalid job/group');
        is($put->tx->res->json->{error}, $in eq 'jobs' ? 'Job 1234 does not exist' : 'Job group 1234 does not exist');
        test_get_comment_invalid_job_or_group('jobs', 1234, 35);
    };

    subtest 'update comment with invalid comment id' => sub {
        my $put = $t->put_ok("/api/v1/$in/$id/comments/33546345" => form => {text => $edited_test_message})->status_is(404, 'comment can not be update for invalid comment ID');
        test_get_comment_invalid_job_or_group('jobs', 1234, 35);
    };

    my $put = $t->put_ok("/api/v1/$in/$id/comments/$new_comment_id" => form => {text => ''})->status_is(400, 'comment can not be updated without text');
    test_get_comment($in, $id, $new_comment_id, $edited_test_message);

    my $delete = $t->delete_ok("/api/v1/$in/$id/comments/$new_comment_id")->status_is(403, 'comment can not be deleted by unauthorized user');
}

subtest 'job comments' => sub {
    test_comments(jobs => 99981);
};

subtest 'group comments' => sub {
    test_comments(groups => 1001);
};

subtest 'admin can delete comments' => sub {
    $app = $t->app;
    $t->ua(OpenQA::Client->new(apikey => 'ARTHURKEY01', apisecret => 'EXCALIBUR')->ioloop(Mojo::IOLoop->singleton));
    $t->app($app);
    my $new_comment_id = test_create_comment(jobs => 99981, $test_message);
    my $delete = $t->delete_ok("/api/v1/jobs/99981/comments/$new_comment_id")->status_is(200, 'comment can be deleted by admin');
    is($delete->tx->res->json->{id}, $new_comment_id, 'deleted comment was the requested one');
    test_get_comment_invalid_comment(jobs => 99981, $new_comment_id);

    subtest 'delete comment with invalid job or group' => sub {
        my $delete = $t->delete_ok("/api/v1/jobs/1234/comments/$new_comment_id")->status_is(404, 'comment can be deleted for invalid job/group');
        is($delete->tx->res->json->{error}, 'Job 1234 does not exist');
        test_get_comment_invalid_job_or_group('jobs', 1234, 35);
    };

    subtest 'delete comment with invalid comment id' => sub {
        my $put = $t->put_ok("/api/v1/jobs/1234/comments/33546345" => form => {text => $edited_test_message})->status_is(404, 'comment can not be deleted for invalid comment ID');
        test_get_comment_invalid_job_or_group('jobs', 1234, 35);
    };
};

subtest 'can not edit comment by other user' => sub {
    my $put = $t->put_ok("/api/v1/jobs/99981/comments/1" => form => {text => $edited_test_message . $another_test_message})->status_is(403, 'editing comments by other users is forbidden');
    test_get_comment(jobs => 99981, 1, $edited_test_message);
};

subtest 'unauthorized users can only read' => sub {
    $app = $t->app;
    $t->ua(OpenQA::Client->new()->ioloop(Mojo::IOLoop->singleton));
    $t->app($app);
    test_get_comment(jobs   => 99981, 1, $edited_test_message);
    test_get_comment(groups => 1001,  2, $edited_test_message);
};

done_testing();
