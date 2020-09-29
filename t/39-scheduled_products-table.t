#!/usr/bin/env perl
# Copyright (C) 2019-2020 SUSE LLC
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

use FindBin;
use lib "$FindBin::Bin/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use Test::MockModule;
use OpenQA::Test::TimeLimit '6';
use OpenQA::Test::Case;
use OpenQA::Utils;

# init test case
my $test_case = OpenQA::Test::Case->new;
$test_case->init_data(skip_fixtures => 1);
my $t = Test::Mojo->new('OpenQA::WebAPI');

my $schema             = $t->app->schema;
my $scheduled_products = $schema->resultset('ScheduledProducts');
my $users              = $schema->resultset('Users');
my $user               = $users->create_user('foo');
my %settings           = (
    distri   => 'openSUSE',
    version  => '15.1',
    flavor   => 'DVD',
    arch     => 'x86_64',
    build    => 'foo',
    settings => {some => 'settings'},
    user_id  => $user->id,
);

# prevent job creation
my $scheduled_products_mock = Test::MockModule->new('OpenQA::Schema::Result::ScheduledProducts');
$scheduled_products_mock->redefine(_generate_jobs => sub { return undef; });

my $scheduled_product;
subtest 'handling assets with invalid name' => sub {
    $scheduled_product = $scheduled_products->create(\%settings);

    is_deeply(
        $scheduled_product->schedule_iso({REPO_0 => ''}),
        {error => 'Asset type and name must not be empty.'},
        'schedule_iso prevents adding assets with empty name',
    );

    $scheduled_product->discard_changes;
    is(
        $scheduled_product->status,
        OpenQA::Schema::Result::ScheduledProducts::SCHEDULED,
        'product marked as scheduled, though'
    );

    $scheduled_product = $scheduled_products->create(\%settings);
    is_deeply(
        $scheduled_product->schedule_iso({REPO_0 => 'invalid'}),
        {
            successful_job_ids => [],
            failed_job_info    => [],
        },
        'schedule_iso allows non-existant assets though',
    );

    $scheduled_product->discard_changes;
    is(
        $scheduled_product->status,
        OpenQA::Schema::Result::ScheduledProducts::SCHEDULED,
        'product marked as scheduled, though'
    );
};

dies_ok(sub { $scheduled_product->schedule_iso(\%settings); }, 'scheduling the same product again prevented');

done_testing();
