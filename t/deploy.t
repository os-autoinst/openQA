#!/usr/bin/env perl

# Copyright 2014-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";

use Test::Warnings ':report_warnings';
use Test::Mojo;
use Mojo::File 'tempdir';
use DBIx::Class::DeploymentHandler;
use SQL::Translator;
use OpenQA::Schema;
use OpenQA::Test::TimeLimit '20';
use OpenQA::Test::Case;
use Mojo::File 'path';
use List::Util 'min';
use Try::Tiny;

plan skip_all => 'set TEST_PG to e.g. "DBI:Pg:dbname=test" to enable this test' unless $ENV{TEST_PG};

# find the oldest still supported schema version which is defined by the oldest deploy folder
# which is still present
my $oldest_still_supported_schema_version
  = min(@{path($FindBin::Bin, '../dbicdh/PostgreSQL/deploy')->list({dir => 1})->map('basename')});
ok($oldest_still_supported_schema_version, 'found oldest still supported schema version');

sub ensure_schema_is_created_and_empty {
    my $dbh = shift->storage->dbh;
    $dbh->do('SET client_min_messages TO WARNING;');
    $dbh->do("drop schema if exists deploy cascade");
    $dbh->do("create schema deploy");
    $dbh->do("SET search_path TO deploy");
}
my $schema = OpenQA::Schema::connect_db(mode => 'test', deploy => 0);
ensure_schema_is_created_and_empty $schema;

my $dh = DBIx::Class::DeploymentHandler->new(
    {
        schema => $schema,
        script_directory => 'dbicdh',
        databases => 'PostgreSQL',
        force_overwrite => 0,
    });
my $deployed_version;
try {
    $deployed_version = $dh->version_storage->database_version;
};
ok(!$deployed_version, 'DB not deployed by plain schema connection with deploy => 0');

my $ret = $schema->deploy;
ok($dh->version_storage->database_version, 'DB deployed');
is($dh->version_storage->database_version, $dh->schema_version, 'Schema at correct version');
is($ret, 2, 'Expected return value (2) for a deployment');

OpenQA::Schema::disconnect_db;
$schema = OpenQA::Schema::connect_db(mode => 'test', deploy => 0);
ensure_schema_is_created_and_empty $schema;

# redeploy DB to the oldest still supported version and check if deployment upgrades the DB
$dh = DBIx::Class::DeploymentHandler->new(
    {
        schema => $schema,
        script_directory => 'dbicdh',
        databases => 'PostgreSQL',
        sql_translator_args => {add_drop_table => 0},
        force_overwrite => 1,
    });
$dh->install({version => $oldest_still_supported_schema_version});
$schema->create_system_user;

ok($dh->version_storage->database_version, 'DB deployed');
is($dh->version_storage->database_version, $oldest_still_supported_schema_version, 'Schema at correct, old, version');
$ret = $schema->deploy;

# insert default fixtures so this test is at least a little bit closer to migrations in production
OpenQA::Test::Database->new->insert_fixtures($schema);

ok($dh->version_storage->database_version, 'DB deployed');
is($dh->version_storage->database_version, $dh->schema_version, 'Schema at correct version');
is($ret, 1, 'Expected return value (1) for an upgrade');

# check another deployment call doesn't do a thing
$ret = $schema->deploy;
ok($dh->version_storage->database_version, 'DB deployed');
is($dh->version_storage->database_version, $dh->schema_version, 'Schema at correct version');
is($ret, 0, 'Expected return value (0) for no action needed');

subtest 'serving common pages works after db migrations' => sub {
    my $t = Test::Mojo->new('OpenQA::WebAPI');
    for my $page (qw(/ /tests /tests/overview /admin/workers /admin/groups /admin/job_templates/1001)) {
        $t->get_ok($page)->status_is(200);
    }
};

subtest 'Full schema init+upgrade cycle works' => sub {
    $ENV{OPENQA_SCHEMA_VERSION_OVERRIDE} = my $schema_version = $dh->schema_version + 1;
    my $new_schema_dir = tempdir;
    my $initdb = "$FindBin::RealBin/../script/initdb";
    my $out = qx{$initdb --dir=$new_schema_dir --prepare_init};
    is $?, 0, 'initdb ok';
    is $out, '', 'initdb shows no errors';
    $ENV{OPENQA_SCHEMA_VERSION_OVERRIDE} = $schema_version = $schema_version + 1;
    $out = qx{$initdb --dir=$new_schema_dir --prepare_init};
    is $?, 0, 'initdb ok for new version';
    is $out, '', 'initdb shows no errors for new version';
    my $upgradedb = "$FindBin::RealBin/../script/upgradedb";
    qx{$upgradedb --dir=$new_schema_dir --prepare_upgrades};
    is $?, 0, 'upgradedb ok';
    is $out, '', 'upgradedb shows no errors';
};

done_testing();
