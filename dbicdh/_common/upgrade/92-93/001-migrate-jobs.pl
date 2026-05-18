#!/usr/bin/env perl

# Copyright 2018 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use 5.018;
use warnings;

sub {
    my ($schema) = @_;

    my $jobs = $schema->resultset('Jobs')->search({state => 'scheduled'});

    while (my $job = $jobs->next) {
        $job->calculate_blocked_by;
    }
  }
