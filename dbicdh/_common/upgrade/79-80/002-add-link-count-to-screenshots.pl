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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use strict;
use warnings;
use DBIx::Class::DeploymentHandler;
use OpenQA::Utils;

sub {
    my ($schema) = @_;

    log_info(
'Scheduling database migration to add link count to screenshots table. This might take a while (e.g. up to an hour).'
    );

    $schema->storage->dbh->prepare(
'UPDATE screenshots SET link_count=subquery.link_count FROM (SELECT screenshot_id, count(screenshot_id) AS link_count FROM screenshot_links GROUP BY screenshot_id) AS subquery WHERE screenshots.id=subquery.screenshot_id'
    )->execute;
  }
