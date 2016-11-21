#!/usr/bin/perl -w

# Copyright (C) 2016 SUSE LLC
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

use File::Basename;
use File::Find;

sub {
    my ($schema) = @_;

    use OpenQA::WebAPI::Plugin::Gru;
    my $gru = OpenQA::WebAPI::Plugin::Gru->new;

    my $max = $schema->resultset('Jobs')->get_column('id')->max || 0;
    my $delta = 1000;
    while ($max > $delta) {
        $gru->enqueue(scan_images_links => {max_job => $max, min_job => $max - $delta}, {priority => -8});
        $max -= $delta;
    }
    # not needed on empty instances
    if ($max) {
        $gru->enqueue(scan_images_links => {max_job => $max, min_job => 0}, {priority => -8});
    }
  }
