# Copyright (C) 2016 SUSE Linux GmbH
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


my $test_case;
my $t;
my $auth;

=head2 acceptance criteria

=item tagged builds have a special mark making them distinguishable from other builds (e.g. a star icon)

=cut

sub set_up {
    $test_case = OpenQA::Test::Case->new;
    $test_case->init_data;
    $t = Test::Mojo->new('OpenQA::WebAPI');
    $auth = {'X-CSRF-Token' => $t->ua->get('/tests')->res->dom->at('meta[name=csrf-token]')->attr('content')};
    $test_case->login($t, 'percival');
}

set_up;

=pod
Given 'group_overview' page
When user creates comment with tag:<build_ref>:important:<tag_ref>
Then on page 'group_overview' rendering icon is shown on important builds
=cut
subtest 'tag icon on group overview on important build' => sub {
    my $tag               = 'tag:0048:important:GM';
    my $unrelated_comment = 'something_else';
    for my $comment ($tag, $unrelated_comment) {
        $t->post_ok('/group_overview/1001/add_comment', $auth => form => {text => $comment})->status_is(302);
    }
    my $get  = $t->get_ok('/group_overview/1001')->status_is(200);
    my @tags = $t->tx->res->dom->find('.tag')->map('text')->each;
    is(scalar @tags, 1,    'one build tagged');
    is($tags[0],     'GM', 'tag description shown');
};

done_testing;
