#!/usr/bin/env perl

# Copyright (C) 2019 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

use strict;
use warnings;
use DBIx::Class::DeploymentHandler;
use OpenQA::Schema;
use OpenQA::Log 'log_info';
use Mojo::File;
use Mojo::JSON 'encode_json';

sub {
    my ($schema) = @_;

    log_info('Setting asset limit explicitely on job group level where previously inherited from parent job group');

    # note: Using manual query here because the script needs to be executed before the "auto" migration of DBIx
    #       which would assume that the migration has already happened.

    my $dbh        = $schema->storage->dbh;
    my $select_sth = $dbh->prepare('select id, default_size_limit_gb from job_group_parents;');
    my $update_sth
      = $dbh->prepare('update job_groups set size_limit_gb = ? where parent_id = ? and size_limit_gb is null;');

    $select_sth->execute;
    while (my $row = $select_sth->fetchrow_hashref) {
        my $parent_group_id    = $row->{id};
        my $default_size_limit = $row->{default_size_limit_gb};
        if (!defined $default_size_limit) {
            log_info(" -> Skipping parent job group $parent_group_id because it has no default size limit");
            next;
        }
        my $affected_rows = $update_sth->execute($default_size_limit, $parent_group_id);
        log_info(
            " -> Set size limit of $affected_rows job groups within parent $parent_group_id to $default_size_limit GiB"
        );
    }
  }
