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

#!perl

use strict;
use warnings;

sub {
    my $schema = shift;

    my $products = $schema->resultset('Products');
    while (my $r = $products->next) {
        my $group = $r->distri;
        if ($r->version ne '*') {
            $group .= "-" . $r->version;
        }
        # now on to some very specific groups :)
        if ($r->distri eq 'opensuse' && $r->flavor =~ m/Staging/) {
            $group = 'opensuse-staging';
        }
        $group = $schema->resultset('JobGroups')->find_or_create({name => $group});
        my $jts = $r->job_templates;
        while (my $j = $jts->next) {
            $j->update({group_id => $group->id});
        }
    }
  }

