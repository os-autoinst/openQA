#!/usr/bin/env perl -w

# Copyright (C) 2014 SUSE Linux Products GmbH
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

BEGIN { unshift @INC, 'lib', 'lib/OpenQA/modules'; }

use strict;

use Test::More;
use DBIx::Class::DeploymentHandler;
use SQL::Translator;

use openqa ();

unlink $openqa::dbfile;

my $schema = openqa::connect_db();

my $dh = DBIx::Class::DeploymentHandler->new(
    {
        schema              => $schema,
        script_directory    => 'dbicdh',
        databases           => 'SQLite',
        sql_translator_args => { add_drop_table => 0, producer_args => { sqlite_version => '3.7' } },
        force_overwrite     => 0,
    }
);
ok(defined $dh->install, "deployed");

my $fn = 't/diagram-v' . $schema->VERSION . '.png';
unlink($fn);
my $trans = SQL::Translator->new(
    parser        => 'SQL::Translator::Parser::DBIx::Class',
    parser_args   => { dbic_schema => $schema },
    producer      => 'Diagram',
    producer_args => {
        out_file         => $fn,
        show_constraints => 1,
        show_datatypes   => 1,
        show_sizes       => 1,
        show_fk_only     => 0,
        title            => 'openQA database schema version '.$schema->VERSION,
    } );

ok($trans->translate, "generate graph");
ok(-e $fn, "graph png exists");

done_testing();
