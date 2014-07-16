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

#!perl

use strict;
use warnings;

# no use case for that yet
#use DBIx::Class::DeploymentHandler::DeployMethod::SQL::Translator::ScriptHelpers 'schema_from_schema_loader';

#schema_from_schema_loader({ naming => 'v4' },
sub {
    my $schema = shift;

    # [1] for deploy, [1,2] for upgrade or downgrade, probably used with _any
    my $versions = shift;

    $schema->resultset('JobStates')->populate([[qw/id name/],[ 0,'scheduled' ],[ 1,'running' ],[ 2,'cancelled' ],[ 3,'waiting'],[ 4,'done'],[ 5,'obsoleted'],]);

    $schema->resultset('JobResults')->populate([[qw/id name/],[ 0,'none' ],[ 1,'passed' ],[ 2,'failed' ],[ 3,'incomplete' ],]);

    # XXX: get rid of worker zero at some point
    $schema->resultset('Workers')->populate([[qw/id host instance backend/],[ 0, 'NONE', 0, 'NONE' ],]);
  }
  #);
