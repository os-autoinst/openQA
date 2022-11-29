#!/usr/bin/env perl
# Copyright 2017-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use Date::Format;
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '8';
use OpenQA::Test::Case;
use OpenQA::Test::Client 'client';
require OpenQA::Schema::Result::Jobs;

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 03-users.pl');
my $t = client(Test::Mojo->new('OpenQA::WebAPI'));
my $bugs = $t->app->schema->resultset('Bugs');
my $bug = $bugs->get_bug('poo#200');
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
    my $now = time;
    my $delta = $now - $update_time + 500;
    $t->get_ok("/api/v1/bugs?created_since=$delta");
    is(scalar(keys %{$t->tx->res->json->{bugs}}), 3, "All reported bugs with delta $delta");
    $t->get_ok('/api/v1/bugs?created_since=100');
    is(scalar(keys %{$t->tx->res->json->{bugs}}), 2, 'Only the latest bugs');
};

subtest 'server-side limit has precedence over user-specified limit' => sub {
    my $limits = OpenQA::App->singleton->config->{misc_limits};
    $limits->{generic_max_limit} = 5;
    $limits->{generic_default_limit} = 2;

    for my $i (1 .. 9) {
        $t->post_ok('/api/v1/bugs', form => {title => "Test-Bug $i", bugid => "bsc#30$i"});
    }

    $t->get_ok('/api/v1/bugs?limit=10', 'query with exceeding user-specified limit for bugs')->status_is(200);
    my $bugs = $t->tx->res->json->{bugs};
    is ref $bugs, 'HASH', 'data returned (1)' and is scalar %$bugs, 5, 'maximum limit for bugs is effective';

    $t->get_ok('/api/v1/bugs?limit=3', 'query with exceeding user-specified limit for bugs')->status_is(200);
    $bugs = $t->tx->res->json->{bugs};
    is ref $bugs, 'HASH', 'data returned (2)' and is scalar %$bugs, 3, 'user limit for bugs is effective';

    $t->get_ok('/api/v1/bugs', 'query with (low) default limit for bugs')->status_is(200);
    $bugs = $t->tx->res->json->{bugs};
    is ref $bugs, 'HASH', 'data returned (3)' and is scalar %$bugs, 2, 'default limit for bugs is effective';
};

subtest 'server-side limit with pagination' => sub {
    subtest 'input validation' => sub {
        $t->get_ok('/api/v1/bugs?limit=a')->status_is(400)
          ->json_is({error_status => 400, error => 'Erroneous parameters (limit invalid)'});
        $t->get_ok('/api/v1/bugs?offset=a')->status_is(400)
          ->json_is({error_status => 400, error => 'Erroneous parameters (offset invalid)'});
    };

    subtest 'navigation with limit' => sub {
        $t->get_ok('/api/v1/bugs?limit=5')->status_is(200)->json_has('/bugs/1')->json_has('/bugs/3')
          ->json_has('/bugs/4')->json_has('/bugs/5')->json_has('/bugs/6')->json_hasnt('/bugs/10')
          ->json_hasnt('/bugs/12');
        my $links = $t->tx->res->headers->links;
        ok $links->{first}, 'has first page';
        ok $links->{next}, 'has next page';
        ok !$links->{prev}, 'no previous page';

        $t->get_ok($links->{next}{link})->status_is(200)->json_has('/bugs/10')->json_has('/bugs/11')
          ->json_has('/bugs/7')->json_has('/bugs/8')->json_has('/bugs/9')->json_hasnt('/bugs/1')
          ->json_hasnt('/bugs/12');
        $links = $t->tx->res->headers->links;
        ok $links->{first}, 'has first page';
        ok $links->{next}, 'has next page';
        ok $links->{prev}, 'has previous page';

        $t->get_ok($links->{next}{link})->status_is(200)->json_has('/bugs/12')->json_has('/bugs/13')
          ->json_hasnt('/bugs/1')->json_hasnt('/bugs/10');
        $links = $t->tx->res->headers->links;
        ok $links->{first}, 'has first page';
        ok !$links->{next}, 'no next page';
        ok $links->{prev}, 'has previous page';

        $t->get_ok($links->{prev}{link})->status_is(200)->json_has('/bugs/10')->json_has('/bugs/11')
          ->json_has('/bugs/7')->json_has('/bugs/8')->json_has('/bugs/9')->json_hasnt('/bugs/1')
          ->json_hasnt('/bugs/12');
        $links = $t->tx->res->headers->links;
        ok $links->{first}, 'has first page';
        ok $links->{next}, 'has next page';
        ok $links->{prev}, 'has previous page';

        $t->get_ok($links->{first}{link})->status_is(200)->json_has('/bugs/1')->json_has('/bugs/3')
          ->json_has('/bugs/4')->json_has('/bugs/5')->json_has('/bugs/6')->json_hasnt('/bugs/10')
          ->json_hasnt('/bugs/12');
        $links = $t->tx->res->headers->links;
        ok $links->{first}, 'has first page';
        ok $links->{next}, 'has next page';
        ok !$links->{prev}, 'no previous page';
    };
};

done_testing();
