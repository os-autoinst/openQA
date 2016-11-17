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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

BEGIN {
    unshift @INC, 'lib';
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;
use OpenQA::IPC;
use OpenQA::Scheduler;
use OpenQA::WebSockets;
use JSON qw/decode_json/;

my $ipc = OpenQA::IPC->ipc('', 1);
my $sh  = OpenQA::Scheduler->new;
my $ws  = OpenQA::WebSockets->new;

my $test_case;
my $t;
my $auth;

sub set_up {
    $test_case = OpenQA::Test::Case->new;
    $test_case->init_data;
    $t = Test::Mojo->new('OpenQA::WebAPI');
    $auth = {'X-CSRF-Token' => $t->ua->get('/tests')->res->dom->at('meta[name=csrf-token]')->attr('content')};
    $test_case->login($t, 'percival');
}

sub comments {
    my ($url) = @_;
    my $get = $t->get_ok($url)->status_is(200);
    return $get->tx->res->dom->find('div.comments .media-comment > p')->map('content');
}

sub restart_with_result {
    my ($old_job, $result) = @_;
    my $get     = $t->post_ok("/api/v1/jobs/$old_job/restart", $auth)->status_is(200);
    my $res     = decode_json($get->tx->res->body);
    my $new_job = $res->{result}[0];
    $t->post_ok("/api/v1/jobs/$new_job/set_done", $auth => form => {result => $result})->status_is(200);
    return $res;
}
set_up;

subtest '"happy path": failed->failed carries over last label' => sub {
    my $label          = 'label:false_positive';
    my $second_label   = 'bsc#1234';
    my $simple_comment = 'just another simple comment';
    for my $comment ($label, $second_label, $simple_comment) {
        $t->post_ok('/api/v1/jobs/99962/comments', $auth => form => {text => $comment})->status_is(200);
    }
    my @comments_previous = @{comments('/tests/99962')};
    is(scalar @comments_previous, 3,               'all entered comments found');
    is($comments_previous[0],     $label,          'comment present on previous test result');
    is($comments_previous[2],     $simple_comment, 'another comment present');
    $t->post_ok('/api/v1/jobs/99963/set_done', $auth => form => {result => 'failed'})->status_is(200);
    my @comments_current = @{comments('/tests/99963')};
    my $comment_must
      = '<a href="https://bugzilla.suse.com/show_bug.cgi?id=1234">bsc#1234</a>(Automatic takeover from <a href="/tests/99962">t#99962</a>)';
    is(join('', @comments_current), $comment_must, 'only one label is carried over');
    like($comments_current[0], qr/\Q$second_label/, 'last entered label found, it is expanded');
};

my $job;
subtest 'failed->passed discards the label' => sub {
    my $res = restart_with_result(99963, 'passed');
    $job = $res->{result}[0];
    my @comments_new = @{comments($res->{test_url}[0])};
    is(scalar @comments_new, 0, 'no labels carried over to passed');
};

subtest 'passed->failed does not carry over old label' => sub {
    my $res = restart_with_result($job, 'failed');
    $job = $res->{result}[0];
    my @comments_new = @{comments($res->{test_url}[0])};
    is(scalar @comments_new, 0, 'no old labels on new failure');
};

subtest 'failed->failed without labels does not fail' => sub {
    my $res = restart_with_result($job, 'failed');
    $job = $res->{result}[0];
    my @comments_new = @{comments($res->{test_url}[0])};
    is(scalar @comments_new, 0, 'nothing there, nothing appears');
};

subtest 'failed->failed labels which are not bugrefs are also carried over' => sub {
    my $label = 'label:any_label';
    $t->post_ok("/api/v1/jobs/$job/comments", $auth => form => {text => $label})->status_is(200);
    my $res          = restart_with_result($job, 'failed');
    my @comments_new = @{comments($res->{test_url}[0])};
    my $comment_must = 'label:any_label(Automatic takeover from <a href="/tests/99985">t#99985</a>)';
    is(join('', @comments_new), $comment_must, 'also simple labels are carried over');
    is($comments_new[0], $label, 'simple label present in new result');
};

done_testing;
