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

my $schema = openqa::connect_db();

my $dh = DH->new(
    {
        schema              => $schema,
        script_directory    => "$FindBin::Bin/../dbicdh",
        databases           => 'SQLite',
        sql_translator_args => { add_drop_table => 0 },
    }
);

$dh->prepare_deploy;
$dh->prepare_upgrade({ from_version => 3, to_version => 4});
$dh->upgrade;
# vim: set sw=4 et:
