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
use OpenQA::Test::Case;
use OpenQA::IPC;
use OpenQA::Scheduler;

my $ipc = OpenQA::IPC->ipc('', 1);
my $sh = OpenQA::Scheduler->new;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

my $t    = Test::Mojo->new('OpenQA::WebAPI');
my $req  = $t->ua->get('/tests');
my $auth = {'X-CSRF-Token' => $req->res->dom->at('meta[name=csrf-token]')->attr('content')};
$test_case->login($t, 'percival');

sub comments {
    my ($url) = @_;
    my $get = $t->get_ok($url)->status_is(200);
    return $get->tx->res->dom->find('div.comments .media-comment ~ p')->map('content');
}

my $label          = 'label:false_positive';
my $simple_comment = 'just another simple comment';
my $second_label   = 'bsc#1234';
for my $comment ($label, $simple_comment, $second_label) {
    $t->post_ok('/tests/99962/add_comment', $auth => form => {text => $comment})->status_is(302);
}
my @comments_previous = @{comments('/tests/99962')};
is(scalar @comments_previous, 3,               'all entered comments found');
is($comments_previous[0],     $label,          'comment present on previous test result');
is($comments_previous[1],     $simple_comment, 'another comment present');
$t->post_ok('/api/v1/jobs/99963/set_done', $auth => form => {result => 'failed'})->status_is(200);
my @comments_current = @{comments('/tests/99963')};
is(scalar @comments_current, 1, 'only labels are carried over');
like($comments_current[0], qr/\Q$second_label/, 'last entered label found, it is expanded');

done_testing;
