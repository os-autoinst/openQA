#!/usr/bin/env perl

# Copyright (C) 2014 SUSE Linux Products GmbH
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

BEGIN { unshift @INC, 'lib', 'lib/OpenQA/modules'; }

use strict;
use warnings;
use Data::Dump qw/pp dd/;
use openqa::distri::sles qw(parse_iso);

use Test::More tests => 5;

my @testdata = (
    {
        iso => "openSUSE-13.1-DVD-Biarch-i586-x86_64-Build0067-Media.iso",
        # not accepted
    },
    {
        iso => 'openSUSE-Factory-staging_core-x86_64-Build0047.0001-Media.iso',
        # not accepted
    },
    {
        iso => 'SLES-12-DVD-x86_64-Build0067-Media1.iso',
        # old style, not accepted
    },
    {
        iso => 'SLE-12-Server-DVD-x86_64-Build0005-Media1.iso',
        params => {
            arch    => "x86_64",
            build   => "0005",
            distri  => "SLES",
            flavor  => "DVD",
            version => 12,
        },
    },
    {
        iso => 'SLE-12-Desktop-DVD-i586-Build1234-Media1.iso',
        params => {
            arch    => "i586",
            build   => "1234",
            distri  => "SLED",
            flavor  => "DVD",
            version => 12,
        },
    },
);

for my $t (@testdata) {
    my $params = openqa::distri::sles::parse_iso($t->{iso});
    if ($t->{params}) {
        is_deeply($params, $t->{params}, $t->{iso});
    } else {
        ok(!defined $params, $t->{iso});
    }
}
