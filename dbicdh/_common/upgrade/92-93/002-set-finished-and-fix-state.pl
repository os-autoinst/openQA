#!/usr/bin/env perl

# Copyright 2018 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

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

    # fix wrong job states previous openQA versions accidentally assigned
    $jobs = $schema->resultset('Jobs')->search(
        {
            state => [OpenQA::Jobs::Constants::SKIPPED, OpenQA::Jobs::Constants::USER_CANCELLED],
        });
    while (my $job = $jobs->next) {
        $job->update({state => OpenQA::Jobs::Constants::CANCELLED});
    }
  }
