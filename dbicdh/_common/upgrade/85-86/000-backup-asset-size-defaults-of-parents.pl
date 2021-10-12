#!/usr/bin/env perl

# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use strict;
use warnings;
use DBIx::Class::DeploymentHandler;
use OpenQA::Schema;
use OpenQA::Log 'log_info';
use Mojo::File;
use Mojo::JSON 'encode_json';

sub {
    my ($schema) = @_;

    log_info('Setting asset limit explicitly on job group level where previously inherited from parent job group');

    # note: Using manual query here because the script needs to be executed before the "auto" migration of DBIx
    #       which would assume that the migration has already happened.

    my $dbh = $schema->storage->dbh;
    my $select_sth = $dbh->prepare('select id, default_size_limit_gb from job_group_parents;');
    my $update_sth
      = $dbh->prepare('update job_groups set size_limit_gb = ? where parent_id = ? and size_limit_gb is null;');

    $select_sth->execute;
    while (my $row = $select_sth->fetchrow_hashref) {
        my $parent_group_id = $row->{id};
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
