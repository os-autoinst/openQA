#!/usr/bin/env perl

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

BEGIN {
    use FindBin qw($Bin);
    use lib "$Bin/../lib", "$Bin/../lib/OpenQA/modules";
}

use strict;
use warnings;
use aliased 'DBIx::Class::DeploymentHandler' => 'DH';
use FindBin;
use lib "$FindBin::Bin/../lib";
use openqa ();
use Schema::Schema;
use Getopt::Long;
use IO::Dir;

my $prepare_upgrades=0;
my $upgrade_database=0;
my $help=0;
my $from_uninitialized_database=0;

my $result = GetOptions ("help" => \$help, 
                      "from_uninitialized_database" => \$from_uninitialized_database,
                      "prepare_upgrades" => \$prepare_upgrades,
                      "upgrade_database"  => \$upgrade_database
);

if ($help) {
    print "Usage: $0 [flags]\n\n";
    print "  --prepare_upgrades : Create the deployment files used to upgrade the database.\n";
    print "                       Don't forget to increase the version before using this\n";
    print "                       and note those files should be commited to the source repo.\n";
    print "  --upgrade_database : Use the generated deployment files created with --prepare_upgrades\n";
    print "                       to actually upgrade a database.\n";
    print "  --from_uninitialized_database : Create and populate an existing database as if it was\n";
    print "                       initialized with the initdb script.\n";
    print "  --help             : This help message.\n";
    exit;
}

my $schema = openqa::connect_db();

my $script_directory="$FindBin::Bin/../dbicdh";

my $dh = DH->new(
    {
        schema              => $schema,
        script_directory    => $script_directory,
        databases           => 'SQLite',
        sql_translator_args => { add_drop_table => 0 },
    }
);

my $version=$dh->schema_version;
my $db_version = $dh->version_storage->database_version;
#print "Schema version: $version\n";
#print "Current DB version: $db_version\n";

my $prev_version=$version-1;
my $upgrade_directory="$prev_version-$version";

my %upgrade_dir;
tie %upgrade_dir, 'IO::Dir', "$script_directory/SQLite/upgrade";
my %deploy_dir;
tie %deploy_dir, 'IO::Dir', "$script_directory/SQLite/deploy";

if ($prepare_upgrades) {
    if (exists $upgrade_dir{$upgrade_directory}) {
        print "The current version $version already has upgrade data generated. Nothing to upgrade\n";
        print "Remove the $script_directory/SQLite/upgrade/$upgrade_directory if you want to regenerate it\n";
        exit 1;
    }

    $dh->prepare_deploy;
    $dh->prepare_upgrade({ from_version => $prev_version, to_version => $version});
}

if ($upgrade_database) {
    if ($from_uninitialized_database) {
       print "'--from_uninitialized_database' not implemented yet";
    }
    $dh->upgrade;
}

# vim: set sw=4 sts=4 et:
