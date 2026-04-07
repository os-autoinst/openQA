#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;
use Test::Warnings ':report_warnings';

use FindBin '$Bin';
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '10';
use OpenQA::Test::Database;
use File::Copy::Recursive qw(dircopy);
use Mojo::File qw(path tempdir);

my $now = time;
my $schema_name = OpenQA::Test::Database::generate_schema_name;
my $schema_version = $OpenQA::Schema::VERSION - 1;
$ENV{OPENQA_DATABASE} = 'test';
$ENV{OPENQA_DATABASE_SEARCH_PATH} = $schema_name;
$ENV{OPENQA_SCHEMA_VERSION_OVERRIDE} = $schema_version;

my $schema = OpenQA::Schema::connect_db(deploy => 0, silent => 1, from_script => 1);
$schema->storage->dbh->do("create schema \"$schema_name\"");

my $tempdir = tempdir;
my $dbicdh_dir = path($FindBin::RealBin, '../dbicdh');
dircopy $dbicdh_dir, $tempdir or BAIL_OUT "Unable to make temporary dbicdh dir: $!";

my $cmd = "$Bin/../script/initdb";
my $output = qx{"$cmd" --prepare_init --init_database --dir="$tempdir" --force --user "$ENV{USER}" 2>&1};
is $?, 0, 'command exited with zero return code';
like $output, qr/overwriting.*$tempdir/i, 'files in temp dbicdh dir specified via --dir overwritten via --force flag';
like $output, qr/Database initialized/i, 'database initialized';
ok $schema->resultset('Users')->find({username => 'system'}), 'system user has been created';

my $sql_mtime = $tempdir->child("PostgreSQL/deploy/$schema_version/001-auto.sql")->stat->mtime;
cmp_ok $sql_mtime, '>=', $now, 'SQL code for deployment of current schema version has been updated';

subtest 'database exists and is up to data' => sub {
    my $output = qx{"$cmd" --init_database --dir="$tempdir" 2>&1};
    is $? >> 8, 4, 'command exited with return code 4';
    like $output, qr/Database already exists and schema is up to date/i, 'nothing to do';
};

$ENV{OPENQA_SCHEMA_VERSION_OVERRIDE} = ++$schema_version;

subtest 'deploy directory already contains the schema' => sub {
    my $output = qx{"$cmd" --prepare_init --init_database --dir="$tempdir" 2>&1};
    is $? >> 8, 1, 'command exited with return code 1';
    unlike $output, qr/overwriting.*$tempdir/i, 'files in temp dbicdh dir specified via --dir overwritten via --force';
    like $output, qr/use.*--force/i, 'use of --force suggested';
};

subtest 'database exists but needs updating' => sub {
    my $output = qx{"$cmd" --prepare_init --init_database --dir="$tempdir" --force 2>&1};
    is $?, 0, 'command exited with zero return code';
    like $output, qr/overwriting.*$tempdir/i, 'files in temp dbicdh dir specified via --dir overwritten via --force';
    like $output, qr/Database already exists, but schema was upgraded/i, 'schema was upgraded';
    my $sql_mtime = $tempdir->child("PostgreSQL/deploy/$schema_version/001-auto.sql")->stat->mtime;
    cmp_ok $sql_mtime, '>=', $now, 'SQL code for deployment of current schema version has been updated';
};

done_testing;
