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

    use OpenQA::Utils;
    opendir(my $dh, $OpenQA::Utils::imagesdir) || die "Can't open /images: $!";
    while (readdir $dh) {
        # schedule a migrate images job for each 3 char directory
        if (m/^([^.]..)$/) {
            $gru->enqueue(scan_images => {prefix => $_}, {priority => -7});
        }
    }
    closedir $dh;
  }
