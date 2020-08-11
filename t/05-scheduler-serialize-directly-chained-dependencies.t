#!/usr/bin/env perl

# Copyright (C) 2020 SUSE LLC
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

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib";
use OpenQA::Scheduler::Model::Jobs;
use Test::Warnings ':report_warnings';

my %cluster_info = (
    0 => {
        directly_chained_children => [1, 6, 7, 8, 12],
        directly_chained_parents  => [],
        chained_children          => [13],               # supposed to be ignored
        chained_parents           => [],                 # supposed to be ignored
    },
    1 => {
        directly_chained_children => [2, 4],
        directly_chained_parents  => [0],
    },
    2 => {
        directly_chained_children => [3],
        directly_chained_parents  => [0],
    },
    3 => {
        directly_chained_children => [],
        directly_chained_parents  => [2],
    },
    4 => {
        directly_chained_children => [5],
        directly_chained_parents  => [0],
    },
    5 => {
        directly_chained_children => [],
        directly_chained_parents  => [4],
    },
    6 => {
        directly_chained_children => [],
        directly_chained_parents  => [0],
    },
    7 => {
        directly_chained_children => [],
        directly_chained_parents  => [0],
    },
    8 => {
        directly_chained_children => [9, 10],
        directly_chained_parents  => [0],
    },
    9 => {
        directly_chained_children => [],
        directly_chained_parents  => [8],
    },
    10 => {
        directly_chained_children => [11],
        directly_chained_parents  => [8],
    },
    11 => {
        directly_chained_children => [],
        directly_chained_parents  => [10],
    },
    12 => {
        directly_chained_children => [],
        directly_chained_parents  => [0],
    },
    13 => {
        directly_chained_children => [14],
        directly_chained_parents  => [0],
        chained_children          => [],      # supposed to be ignored
        chained_parents           => [13],    # supposed to be ignored
    },
    14 => {
        directly_chained_children => [],
        directly_chained_parents  => [13],
    },
);
# notes: * The array directly_chained_parents is actually not used by the algorithm. From the test perspective
#          we don't want to rely on that detail, though.
#        * The direct chain is interrupted between 12 and 13 by a regularily chained dependency. Hence there
#          are two distinct clusters of directly chained dependencies present.

my @expected_sequence = (2, 3);
my ($computed_sequence, $visited)
  = OpenQA::Scheduler::Model::Jobs::_serialize_directly_chained_job_sequence(2, \%cluster_info);
is_deeply($computed_sequence, \@expected_sequence, 'sub sequence starting from job 2')
  or diag explain $computed_sequence;
is_deeply([sort @$visited], [2, 3], 'relevant jobs visited');

@expected_sequence = (1, [2, 3], [4, 5]);
($computed_sequence, $visited)
  = OpenQA::Scheduler::Model::Jobs::_serialize_directly_chained_job_sequence(1, \%cluster_info);
is_deeply($computed_sequence, \@expected_sequence, 'sub sequence starting from job 1')
  or diag explain $computed_sequence;
is_deeply([sort @$visited], [1, 2, 3, 4, 5], 'relevant jobs visited');

@expected_sequence = (0, [1, [2, 3], [4, 5]], 6, 7, [8, 9, [10, 11]], 12);
($computed_sequence, $visited)
  = OpenQA::Scheduler::Model::Jobs::_serialize_directly_chained_job_sequence(0, \%cluster_info);
is_deeply($computed_sequence, \@expected_sequence, 'whole sequence starting from job 0')
  or diag explain $computed_sequence;
is_deeply([sort @$visited], [0, 1, 10, 11, 12, 2, 3, 4, 5, 6, 7, 8, 9], 'relevant jobs visited');

@expected_sequence = (13, 14);
($computed_sequence, $visited)
  = OpenQA::Scheduler::Model::Jobs::_serialize_directly_chained_job_sequence(13, \%cluster_info);
is_deeply($computed_sequence, \@expected_sequence, 'whole sequence starting from job 13')
  or diag explain $computed_sequence;
is_deeply([sort @$visited], [13, 14], 'relevant jobs visited');

# provide a sort function to control the order between multiple children of the same parent
my %sort_criteria = (12 => 'anfang', 7 => 'danach', 6 => 'mitte', 8 => 'nach mitte', 1 => 'zuletzt');
my $sort_function = sub {
    return [sort { ($sort_criteria{$a} // $a) cmp($sort_criteria{$b} // $b) } @{shift()}];
};
@expected_sequence = (0, 12, 7, 6, [8, [10, 11], 9], [1, [2, 3], [4, 5]]);
($computed_sequence, $visited)
  = OpenQA::Scheduler::Model::Jobs::_serialize_directly_chained_job_sequence(0, \%cluster_info, $sort_function);
is_deeply($computed_sequence, \@expected_sequence, 'sorting criteria overrides sorting by ID')
  or diag explain $computed_sequence;

# introduce a cycle
push(@{$cluster_info{6}->{directly_chained_children}}, 12);
throws_ok(
    sub {
        OpenQA::Scheduler::Model::Jobs::_serialize_directly_chained_job_sequence(0, \%cluster_info);
    },
    qr/cycle at (6|12)/,
    'compution dies on cycle'
);

done_testing();
