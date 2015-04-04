#!/usr/bin/perl -w

# Copyright (C) 2015 SUSE Linux GmbH
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
use warnings;

sub {
    my $schema = shift;

    use OpenQA::Plugin::Gru;

    my $gru = OpenQA::Plugin::Gru->new;

    my $jobs = $schema->resultset('Jobs');
    while (my $job = $jobs->next) {
        next unless $job->result_dir && -d $job->result_dir;
        my $cleanday = $job->t_created->add(days => 14);
        $gru->enqueue(reduce_result => $job->result_dir, { run_at => $cleanday });
    }
  }
