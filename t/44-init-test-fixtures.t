#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;
use Test::Warnings ':report_warnings';
use List::Util qw(uniq);

use FindBin '$Bin';
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '20';
use OpenQA::Test::Database;

my $schema_name = OpenQA::Test::Database::generate_schema_name;
$ENV{OPENQA_DATABASE} = 'test';
$ENV{OPENQA_DATABASE_SEARCH_PATH} = $schema_name;

my $schema = OpenQA::Schema::connect_db(deploy => 0, silent => $ENV{HARNESS_IS_VERBOSE} ? 0 : 1, from_script => 1);
$schema->storage->dbh->do("create schema \"$schema_name\"");

my $cmd = "$Bin/../tools/init-test-fixtures";

subtest 'run with default fixtures and verify database population' => sub {
    my $output = qx{"$cmd" 2>&1};
    is $?, 0, 'command exited with zero return code';
    like $output, qr/openQA Interactive Test Environment Initialized Successfully/i, 'success header printed';
    like $output, qr/Database resets and schema deployed onto '$schema_name'/i, 'correct schema reported';

    ok $schema->resultset('Users')->find({username => 'Demo'}), 'Demo user from 03-users.pl exists in database';
    ok $schema->resultset('Jobs')->find({id => 80000}), 'Standard jobs from 01-jobs.pl are populated';

    my $assets = $schema->resultset('Assets');
    ok $assets->count > 0, 'Assets table is populated';
    is_deeply [uniq map { $_->size } $assets->all], [0], 'assume_all_assets_exist sets all asset sizes to 0';
};

subtest 'run with custom fixtures subset' => sub {
    my $output = qx{"$cmd" --fixtures="03-users.pl" 2>&1};
    is $?, 0, 'command exited with zero return code';
    like $output, qr/Loaded fixtures matching: 03-users\.pl/i, 'custom fixture glob reported';
};

subtest 'run with help option' => sub {
    my $output = qx{"$cmd" --help 2>&1};
    is $?, 0, 'command exited with zero return code';
    like $output, qr/Usage:/i, 'usage information displayed';
    like $output, qr/--fixtures/i, 'fixtures option documented';
};

$schema->storage->dbh->do('SET client_min_messages TO WARNING');
$schema->storage->dbh->do("drop schema \"$schema_name\" cascade");

done_testing;
