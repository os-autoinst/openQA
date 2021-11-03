#!/usr/bin/env perl

# Copyright 2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Jobs::Constants;
use OpenQA::Scheduler::Model::Jobs;
use OpenQA::Test::TimeLimit '10';
use Test::Warnings ':report_warnings';

my %cluster_info = (
    0 => {
        directly_chained_children => [1, 6, 7, 8, 12],
        directly_chained_parents => [],
        chained_children => [13],    # supposed to be ignored
        chained_parents => [],    # supposed to be ignored
        state => SCHEDULED,
    },
    1 => {
        directly_chained_children => [2, 4],
        directly_chained_parents => [0],
        state => SCHEDULED,
    },
    2 => {
        directly_chained_children => [3],
        directly_chained_parents => [0],
        state => SCHEDULED,
    },
    3 => {
        directly_chained_children => [],
        directly_chained_parents => [2],
        state => SCHEDULED,
    },
    4 => {
        directly_chained_children => [5],
        directly_chained_parents => [0],
        state => SCHEDULED,
    },
    5 => {
        directly_chained_children => [],
        directly_chained_parents => [4],
        state => SCHEDULED,
    },
    6 => {
        directly_chained_children => [],
        directly_chained_parents => [0],
        state => SCHEDULED,
    },
    7 => {
        directly_chained_children => [],
        directly_chained_parents => [0],
        state => SCHEDULED,
    },
    8 => {
        directly_chained_children => [9, 10],
        directly_chained_parents => [0],
        state => SCHEDULED,
    },
    9 => {
        directly_chained_children => [],
        directly_chained_parents => [8],
        state => SCHEDULED,
    },
    10 => {
        directly_chained_children => [11],
        directly_chained_parents => [8],
        state => SCHEDULED,
    },
    11 => {
        directly_chained_children => [],
        directly_chained_parents => [10],
        state => SCHEDULED,
    },
    12 => {
        directly_chained_children => [],
        directly_chained_parents => [0],
        state => SCHEDULED,
    },
    13 => {
        directly_chained_children => [14],
        directly_chained_parents => [0],
        chained_children => [],    # supposed to be ignored
        chained_parents => [13],    # supposed to be ignored
        state => SCHEDULED,
    },
    14 => {
        directly_chained_children => [],
        directly_chained_parents => [13],
        state => SCHEDULED,
    },
);
# notes: * The array directly_chained_parents is actually not used by the algorithm. From the test perspective
#          we don't want to rely on that detail, though.
#        * The direct chain is interrupted between 12 and 13 by a regularly chained dependency. Hence there
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

subtest 'jobs which are not scheduled anymore are skipped' => sub {
    $cluster_info{$_}->{state} = DONE for (1, 9);
    @expected_sequence = (0, 6, 7, [8, [10, 11]], 12);
    ($computed_sequence, $visited)
      = OpenQA::Scheduler::Model::Jobs::_serialize_directly_chained_job_sequence(0, \%cluster_info);
    is_deeply($computed_sequence, \@expected_sequence, 'subchains starting from 1 and 9 skipped')
      or diag explain $computed_sequence;
    is_deeply([sort @$visited], [0, 10, 11, 12, 6, 7, 8], 'relevant jobs visited');
};

$cluster_info{$_}->{state} = SCHEDULED for (1, 9);

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
