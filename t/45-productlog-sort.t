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
use OpenQA::Test::TimeLimit '5';
use OpenQA::Schema::Result::ScheduledProducts qw(ADDED CANCELLING SCHEDULING);

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
        status => CANCELLING,
        distri => 'opensuse-tumbleweed',
        version => '3-tumbleweed',
        flavor => 'server-dvd',
        arch => 'x86_64',
        build => '20260514',
        iso => 'opensuse-tumbleweed-server-dvd-x86_64-20260514.iso'
    },
    {
        status => ADDED,
        distri => 'opensuse-leap',
        version => '1-leap-15.6',
        flavor => 'dvd',
        arch => 'ppc64le',
        build => 'build0012',
        iso => 'opensuse-leap-15.6-dvd-ppc64le-build0012.iso'
    },
    {
        status => SCHEDULING,
        distri => 'sle',
        version => '2-sle-15-sp6',
        flavor => 'online',
        arch => 'aarch64',
        build => 'build0042',
        iso => 'sle-15-sp6-online-aarch64-build0042.iso'
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
    # The expected order below is determined by the values stored above.
    my %expected = (
        # column_index => [expected order of created scheduled products]
        0 => [sort { $a <=> $b } @created_ids],    # ID asc
        3 => [@created_ids[1, 0, 2]],    # Status: added, cancelling, scheduling
        4 => [@created_ids[1, 0, 2]],    # Distri: opensuse-leap, opensuse-tumbleweed, sle
        5 => [@created_ids[1, 2, 0]],    # Version: 1-leap-15.6, 2-sle-15-sp6, 3-tumbleweed
        6 => [@created_ids[1, 2, 0]],    # Flavor: dvd, online, server-dvd
        7 => [@created_ids[2, 1, 0]],    # Arch: aarch64, ppc64le, x86_64
        8 => [@created_ids[0, 1, 2]],    # Build: 20260514, build0012, build0042
        9 => [@created_ids[1, 0, 2]],    # ISO: opensuse-leap..., opensuse-tumbleweed..., sle...
    );
    for my $column_index (sort { $a <=> $b } keys %expected) {
        my $rows = _fetch_order($column_index, 'asc');
        is_deeply _ids_in_set($rows), $expected{$column_index},
          "ascending sort by column $column_index returns rows in expected order"
          or always_explain {column => $column_index, rows => $rows};
    }
};

subtest 'non-orderable columns fall back to ID order' => sub {
    my $expected = [sort { $a <=> $b } @created_ids];
    for my $column_index (2, 10) {
        my $rows = _fetch_order($column_index, 'asc');
        is_deeply _ids_in_set($rows), $expected, "column $column_index does not add a misleading sort";
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
