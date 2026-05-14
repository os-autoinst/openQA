#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Mojo::Base -signatures;
use Mojo::URL;
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::Case;
use OpenQA::Test::TimeLimit '10';

OpenQA::Test::Case->new->init_data(fixtures_glob => '03-users.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');
my $schema = $t->app->schema;
my $scheduled_products = $schema->resultset('ScheduledProducts');
my $user = $schema->resultset('Users')->create_user('foo');

# Pre-populate the table with deliberately scrambled values so each column
# yields a different order. This makes off-by-one mismatches between the
# server-side `columns` array and the DataTable column order detectable.
my @products = (
    {
        status => 'cancelling',
        distri => 'd-c',
        version => 'v-c',
        flavor => 'f-c',
        arch => 'a-c',
        build => 'b-c',
        iso => 'i-c'
    },
    {
        status => 'added',
        distri => 'd-a',
        version => 'v-b',
        flavor => 'f-a',
        arch => 'a-b',
        build => 'b-a',
        iso => 'i-b'
    },
    {
        status => 'scheduling',
        distri => 'd-b',
        version => 'v-a',
        flavor => 'f-b',
        arch => 'a-a',
        build => 'b-b',
        iso => 'i-a'
    },
);
my @created_ids = map { $scheduled_products->create({%$_, user_id => $user->id, settings => {}})->id } @products;

sub _fetch_order ($column_index, $direction = 'asc') {
    my $url = Mojo::URL->new('/admin/productlog/ajax')
      ->query(['order[0][column]' => $column_index, 'order[0][dir]' => $direction, 'start' => 0, 'length' => 100]);
    return $t->get_ok($url)->status_is(200)->tx->res->json('/data');
}

# Restrict the result to the rows we created so unrelated rows cannot mask a
# sort regression.
sub _ids_in_set ($rows) {
    my %ours = map { $_ => 1 } @created_ids;
    return [grep { $ours{$_} } map { $_->{id} } @$rows];
}

subtest 'sort by each column maps to the expected database field' => sub {
    # The expected order below is determined by the values stored above:
    # sorting by flavor asc must group "f-a" before "f-b" before "f-c", and so on.
    my %expected = (
        # column_index => [expected order of created scheduled products]
        0 => [sort { $a <=> $b } @created_ids],    # ID asc
        3 => [@created_ids[1, 0, 2]],    # Status: added, cancelling, scheduling
        4 => [@created_ids[1, 2, 0]],    # Distri: d-a, d-b, d-c
        5 => [@created_ids[2, 1, 0]],    # Version: v-a, v-b, v-c
        6 => [@created_ids[1, 2, 0]],    # Flavor: f-a, f-b, f-c
        7 => [@created_ids[2, 1, 0]],    # Arch: a-a, a-b, a-c
        8 => [@created_ids[1, 2, 0]],    # Build: b-a, b-b, b-c
        9 => [@created_ids[2, 1, 0]],    # ISO: i-a, i-b, i-c
    );
    for my $column_index (sort { $a <=> $b } keys %expected) {
        my $rows = _fetch_order($column_index, 'asc');
        is_deeply _ids_in_set($rows), $expected{$column_index},
          "ascending sort by column $column_index returns rows in expected order"
          or always_explain {column => $column_index, rows => $rows};
    }
};

subtest 'descending sort reverses the order' => sub {
    my $asc = _ids_in_set(_fetch_order(6, 'asc'));
    my $desc = _ids_in_set(_fetch_order(6, 'desc'));
    is_deeply $desc, [reverse @$asc], 'flavor descending is the reverse of ascending';
};

subtest 'rows-per-page parameter respected' => sub {
    my $url = Mojo::URL->new('/admin/productlog/ajax')
      ->query(['order[0][column]' => 0, 'order[0][dir]' => 'asc', 'start' => 0, 'length' => 1]);
    my $rows = $t->get_ok($url)->status_is(200)->tx->res->json('/data');
    is scalar @$rows, 1, 'length parameter limits returned rows';
};

done_testing();
