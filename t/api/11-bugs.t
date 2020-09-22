#!/usr/bin/env perl
# Copyright (C) 2017-2020 SUSE LLC
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

use Date::Format;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '16';
use OpenQA::Test::Case;
use OpenQA::Test::Client 'client';
require OpenQA::Schema::Result::Jobs;

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 03-users.pl');
my $t    = client(Test::Mojo->new('OpenQA::WebAPI'));
my $bugs = $t->app->schema->resultset('Bugs');
my $bug  = $bugs->get_bug('poo#200');
is($bugs->first->bugid, 'poo#200', 'Test bug inserted');

subtest 'Properties' => sub {
    $t->get_ok('/api/v1/bugs')->json_is('/bugs/1' => 'poo#200', 'Bug entry exists');
    $t->get_ok('/api/v1/bugs?refreshable=1')->json_is('/bugs/1' => 'poo#200', 'Bug entry is refreshable');
    $t->put_ok('/api/v1/bugs/1', form => {title => "foobar", existing => 1})->json_is('/id' => 1, 'Bug #1 updated');
    $t->put_ok('/api/v1/bugs/2', form => {title => "foobar", existing => 1})->status_is(404, 'Bug #2 not yet existing');
    $t->get_ok('/api/v1/bugs/1')->json_is('/title', 'foobar', 'Bug has correct title');
    is_deeply(
        [sort keys %{$t->tx->res->json}],
        [qw(assigned assignee bugid existing id open priority refreshed resolution status t_created t_updated title)],
        'All expected columns exposed'
    );
};

subtest 'Refreshable' => sub {
    $t->get_ok('/api/v1/bugs?refreshable=1')->json_is('/bugs', {}, 'All bugs are refreshed');
    $t->post_ok('/api/v1/bugs', form => {title => "foobar2", bugid => 'poo#201', existing => 1, refreshed => 1})
      ->json_is('/id' => 2, 'Bug #2 created');
    return diag explain $t->tx->res->body unless $t->success;
    $t->get_ok('/api/v1/bugs/2')->json_is('/title' => 'foobar2', 'Bug #2 has correct title');

    $t->delete_ok('/api/v1/bugs/2');
    $t->get_ok('/api/v1/bugs/2')->status_is(404, 'Bug #2 deleted');

    $t->delete_ok('/api/v1/bugs/2')->status_is(404, 'Bug #2 already deleted');
};

subtest 'Comments' => sub {
    $t->post_ok('/api/v1/jobs/99926/comments', form => {text => 'wicked bug: jsc#SLE-42999'});
    $t->get_ok('/api/v1/bugs/3')->json_is('/bugid' => 'jsc#SLE-42999', 'Bug was created by comment post');
};

subtest 'Created since' => sub {
    $t->post_ok('/api/v1/bugs', form => {title => "new", bugid => 'bsc#123'});
    return diag explain $t->tx->res->body unless $t->success;
    ok(my $bugid = $t->tx->res->json->{id}, "Bug ID returned") or return;
    my $update_time = time;
    ok(my $bug = $bugs->find($bugid), "Bug $bugid found in the database") or return;
    $bug->update({t_created => time2str('%Y-%m-%d %H:%M:%S', $update_time - 490, 'UTC')});
    my $now   = time;
    my $delta = $now - $update_time + 500;
    $t->get_ok("/api/v1/bugs?created_since=$delta");
    is(scalar(keys %{$t->tx->res->json->{bugs}}), 3, "All reported bugs with delta $delta");
    $t->get_ok('/api/v1/bugs?created_since=100');
    is(scalar(keys %{$t->tx->res->json->{bugs}}), 2, 'Only the latest bugs');
};

done_testing();
