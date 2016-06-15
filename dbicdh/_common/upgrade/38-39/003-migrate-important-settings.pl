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

    my $jobs = $schema->resultset("Jobs")->search({}, {columns => [qw/id/]});

    while (my $job = $jobs->next) {
        # we can't use any model functions as they rely on new DB structure
        my $jss = $schema->resultset("JobSettings")->search(
            {
                job_id => $job->id,
                key    => {-in => [qw/DISTRI VERSION FLAVOR ARCH MACHINE BUILD TEST/]}});
        my $updates;
        while (my $js = $jss->next) {
            $updates->{$js->key} = $js->value;
        }
        $job->update($updates);
    }
  }

