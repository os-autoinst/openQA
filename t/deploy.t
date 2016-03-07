#!/usr/bin/env perl -w

# Copyright (C) 2014-2016 SUSE LLC
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

BEGIN { unshift @INC, 'lib'; }

use strict;

use Test::More;
use Test::Warnings;
use DBIx::Class::DeploymentHandler;
use SQL::Translator;
use OpenQA::Schema;
use Try::Tiny;

my $schema = OpenQA::Schema::connect_db('test');
my $dh     = DBIx::Class::DeploymentHandler->new(
    {
        schema              => $schema,
        script_directory    => 'dbicdh',
        databases           => 'SQLite',
        sql_translator_args => {add_drop_table => 0, producer_args => {sqlite_version => '3.7'}},
        force_overwrite     => 0,
    });
my $deployed_version;
try {
    $deployed_version = $dh->version_storage->database_version;
};
ok(!$deployed_version, 'DB not deployed by plain schema connection');

OpenQA::Schema::deployment_check($schema);
ok($dh->version_storage->database_version, 'DB deployed');
is($dh->version_storage->database_version, $dh->schema_version, 'Schema at correct version');

$schema->storage->with_deferred_fk_checks(
    sub {
        for my $source ($schema->sources) {
            try {
                $schema->storage->dbh->do('DROP TABLE ' . $source);
            };
        }
    });

OpenQA::Schema::disconnect_db;
$schema = OpenQA::Schema::connect_db('test');
# redeploy DB to older version and check if deployment_check upgrades the DB
$dh = DBIx::Class::DeploymentHandler->new(
    {
        schema              => $schema,
        script_directory    => 'dbicdh',
        databases           => 'SQLite',
        sql_translator_args => {add_drop_table => 0, producer_args => {sqlite_version => '3.7'}},
        force_overwrite     => 1,
    });
$dh->install({version => $dh->schema_version - 2});
ok($dh->version_storage->database_version, 'DB deployed');
is($dh->version_storage->database_version, $dh->schema_version - 2, 'Schema at correct, old, version');
OpenQA::Schema::deployment_check($schema);
ok($dh->version_storage->database_version, 'DB deployed');
is($dh->version_storage->database_version, $dh->schema_version, 'Schema at correct version');

# check another deployment_check call doesn't do a thing
OpenQA::Schema::deployment_check($schema);
ok($dh->version_storage->database_version, 'DB deployed');
is($dh->version_storage->database_version, $dh->schema_version, 'Schema at correct version');

SKIP: {
    eval { require SQL::Translator::Producer::Diagram; };

    skip "SQL::Translator::Producer::Diagram not functional", 2 if "$@";

    my $fn = 't/diagram-v' . $schema->VERSION . '.png';
    unlink($fn);
    my $trans = SQL::Translator->new(
        parser        => 'SQL::Translator::Parser::DBIx::Class',
        parser_args   => {dbic_schema => $schema},
        producer      => 'Diagram',
        producer_args => {
            out_file         => $fn,
            show_constraints => 1,
            show_datatypes   => 1,
            show_sizes       => 1,
            show_fk_only     => 0,
            title            => 'openQA database schema version ' . $schema->VERSION,
        });

    ok($trans->translate, "generate graph");
    ok(-e $fn,            "graph png exists");
}

done_testing();
