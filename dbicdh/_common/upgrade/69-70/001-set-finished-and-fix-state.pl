#!/usr/bin/env perl

# Copyright (C) 2018 SUSE LLC
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
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;

sub {
    my $schema = shift;

    # ensure all jobs in final states including wrongly assigned ones have t_finished assigned
    my $jobs = $schema->resultset('Jobs')->search(
        {
            state => [
                OpenQA::Jobs::Constants::FINAL_STATES, OpenQA::Jobs::Constants::SKIPPED,
                OpenQA::Jobs::Constants::USER_CANCELLED
            ],
            t_finished => undef,
        });
    while (my $job = $jobs->next) {
        $job->update({t_finished => ($job->t_started // $job->t_created)});
    }

    # fix wrong job states previous openQA versions accidently assigned
    $jobs = $schema->resultset('Jobs')->search(
        {
            state => [OpenQA::Jobs::Constants::SKIPPED, OpenQA::Jobs::Constants::USER_CANCELLED],
        });
    while (my $job = $jobs->next) {
        $job->update({state => OpenQA::Jobs::Constants::CANCELLED});
    }
  }
