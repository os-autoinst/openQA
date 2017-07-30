#!/usr/bin/env perl -w

# Copyright (C) 2017 SUSE LLC
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
# with this program; if not, see <http://www.gnu.org/licenses/>.

use 5.018;
use warnings;

sub {
    my ($schema) = @_;

    my $jobs = $schema->resultset('Jobs');

    while (my $job = $jobs->next) {
        my $stats = {passed => 0, failed => 0, softfailed => 0, none => 0};

        my $query = $schema->resultset("JobModules")->search(
            {job_id => $job->id},
            {
                select   => ['job_id', 'result', {count => 'id'}],
                as       => [qw(job_id result count)],
                group_by => [qw(job_id result)]});

        while (my $line = $query->next) {
            $stats->{$line->result} = $line->get_column('count');
        }
        $job->update(
            {
                passed_module_count     => $stats->{passed},
                failed_module_count     => $stats->{failed},
                softfailed_module_count => $stats->{softfailed},
                skipped_module_count    => $stats->{none},
            });
    }
  }
