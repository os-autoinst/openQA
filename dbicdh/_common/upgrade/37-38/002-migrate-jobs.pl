#!/usr/bin/env perl

# Copyright (C) 2015 SUSE LLC
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

use strict;
use OpenQA::Schema;
use DBIx::Class::DeploymentHandler;

sub {
    my $schema = shift;

    my $jobs = $schema->resultset("Jobs")->search({worker_id => {'!=' => 0}}, {columns => [qw/id worker_id/]});

    while (my $job = $jobs->next) {
        my $worker = $schema->resultset("Workers")->search({id => $job->get_column('worker_id')});
        $worker->update({job_id => $job->id}) if $worker;
    }
  }

