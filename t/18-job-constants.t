#!/usr/bin/env perl

# Copyright (C) 2014-2020 SUSE LLC
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

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use OpenQA::Jobs::Constants;

# This test exists for a single purpose: it asserts that all job
# constants are exactly what they are. If you change the job constants
# this test should fail. The purpose of the failure is to remind you
# that these constants are mirrored in the Python client library:

# https://github.com/os-autoinst/openQA-python-client

# and you should not change them without filing an issue or,
# preferably, a pull request there with the same change(s). Also that
# there are external consumers of these constants so changing them
# (especially removing any) should be avoided if possible.

## STATES

is(SCHEDULED, 'scheduled', 'scheduled');
is(ASSIGNED,  'assigned',  'assigned');
is(SETUP,     'setup',     'setup');
is(RUNNING,   'running',   'running');
is(UPLOADING, 'uploading', 'uploading');
is(CANCELLED, 'cancelled', 'cancelled');
is(DONE,      'done',      'done');

my @states        = STATES;
my @pending       = PENDING_STATES;
my @execution     = EXECUTION_STATES;
my @pre_execution = PRE_EXECUTION_STATES;
my @final         = FINAL_STATES;
is_deeply(\@states, [SCHEDULED, ASSIGNED, SETUP, RUNNING, UPLOADING, DONE, CANCELLED], 'states');
is_deeply(\@pending, [SCHEDULED, ASSIGNED, SETUP, RUNNING, UPLOADING], 'pending_states');
is_deeply(\@execution, [ASSIGNED, SETUP, RUNNING, UPLOADING], 'execution_states');
is_deeply(\@pre_execution, [SCHEDULED],       'pre_execution_states');
is_deeply(\@final,         [DONE, CANCELLED], 'final_states');

# are these meant to be exported?
is(OpenQA::Jobs::Constants::PRE_EXECUTION, 'pre_execution', 'pre_execution');
is(OpenQA::Jobs::Constants::EXECUTION,     'execution',     'execution');
is(OpenQA::Jobs::Constants::FINAL,         'final',         'final');

## RESULTS

is(NONE,               'none',               'none');
is(PASSED,             'passed',             'passed');
is(SOFTFAILED,         'softfailed',         'softfailed');
is(FAILED,             'failed',             'failed');
is(INCOMPLETE,         'incomplete',         'incomplete');
is(SKIPPED,            'skipped',            'skipped');
is(OBSOLETED,          'obsoleted',          'obsoleted');
is(PARALLEL_FAILED,    'parallel_failed',    'parallel_failed');
is(PARALLEL_RESTARTED, 'parallel_restarted', 'parallel_restarted');
is(USER_CANCELLED,     'user_cancelled',     'user_cancelled');
is(USER_RESTARTED,     'user_restarted',     'user_restarted');
is(TIMEOUT_EXCEEDED,   'timeout_exceeded',   'timeout_exceeded');

my @results      = RESULTS;
my @complete     = COMPLETE_RESULTS;
my @ok           = OK_RESULTS;
my @not_complete = NOT_COMPLETE_RESULTS;
my @aborted      = ABORTED_RESULTS;
my @not_ok       = NOT_OK_RESULTS;

is_deeply(
    \@results,
    [
        NONE,               PASSED,         SOFTFAILED,     FAILED,
        INCOMPLETE,         SKIPPED,        OBSOLETED,      PARALLEL_FAILED,
        PARALLEL_RESTARTED, USER_CANCELLED, USER_RESTARTED, TIMEOUT_EXCEEDED
    ],
    'results'
);
is_deeply(\@complete, [PASSED, SOFTFAILED, FAILED], 'complete_results');
is_deeply(\@ok,           [PASSED,     SOFTFAILED],       'ok_results');
is_deeply(\@not_complete, [INCOMPLETE, TIMEOUT_EXCEEDED], 'not_complete_results');
is_deeply(\@aborted, [SKIPPED, OBSOLETED, PARALLEL_FAILED, PARALLEL_RESTARTED, USER_CANCELLED, USER_RESTARTED],
    'aborted_results');
is_deeply(\@not_ok, [FAILED, NOT_COMPLETE_RESULTS, ABORTED_RESULTS], 'not_ok_results');

# again: are these meant to be exported?
is(OpenQA::Jobs::Constants::COMPLETE,     'complete',     'complete');
is(OpenQA::Jobs::Constants::NOT_COMPLETE, 'not_complete', 'not_complete');
is(OpenQA::Jobs::Constants::ABORTED,      'aborted',      'aborted');

done_testing();
