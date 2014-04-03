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
use openqa::distri::opensuse qw(parse_iso);

use Test::More tests => 13;

my @testdata = (
    {
        iso => "openSUSE-13.1-DVD-Biarch-i586-x86_64-Build0067-Media.iso",
        params => {
            'distri' => 'openSUSE',
            'arch' => 'i586-x86_64',
            'version' => '13.1',
            'build' => '0067',
            'flavor' => 'DVD-Biarch'
        },
    },
    {
        iso => "openSUSE-13.1-Promo-DVD-OpenSourcePress-i586-x86_64-Build0002-Media.iso",
        params => {
            'distri' => 'openSUSE',
            'arch' => 'i586-x86_64',
            'version' => '13.1',
            'build' => '0002',
            'flavor' => 'Promo-DVD-OpenSourcePress'
        },
    },
    {
        iso => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
        params => {
            'distri' => 'openSUSE',
            'arch' => 'x86_64',
            'version' => 'Factory',
            'build' => '0725',
            'flavor' => 'DVD'
        },
    },
    {
        iso => "openSUSE-13.1-KDE-Live-x86_64-Build0034-Media.iso",
        params => {
            'distri' => 'openSUSE',
            'arch' => 'x86_64',
            'version' => '13.1',
            'build' => '0034',
            'flavor' => 'KDE-Live'
        },
    },
    {
        iso => "openSUSE-13.1-GNOME-Live-i586-Build0045-Media.iso",
        params => {
            'distri' => 'openSUSE',
            'arch' => 'i586',
            'version' => '13.1',
            'build' => '0045',
            'flavor' => 'GNOME-Live'
        },
    },
    {
        iso => "openSUSE-13.1-NET-i586-Build0042-Media.iso",
        params => {
            'distri' => 'openSUSE',
            'arch' => 'i586',
            'version' => '13.1',
            'build' => '0042',
            'flavor' => 'NET'
        },
    },
    {
        iso => "openSUSE-13.1-Promo-DVD-x86_64-Build0066-Media.iso",
        params => {
            'distri' => 'openSUSE',
            'arch' => 'x86_64',
            'version' => '13.1',
            'build' => '0066',
            'flavor' => 'Promo-DVD'
        },
    },
    {
        iso => "openSUSE-13.1-Rescue-CD-i686-Build0066-Media.iso",
        params => {
            'distri' => 'openSUSE',
            'arch' => 'i686',
            'version' => '13.1',
            'build' => '0066',
            'flavor' => 'Rescue-CD'
        },
    },
    {
        iso => 'SLES-12-DVD-x86_64-Build0067-Media1.iso',
        # not accepted
    },
    {
        iso => 'SLED-12-DVD-x86_64-Build0044-Media1.iso',
        # not accepted
    },
    {
        iso => 'SLE-12-Server-DVD-x86_64-Build0005-Media1.iso',
        # not accepted
    },

    {
        iso => 'openSUSE-Factory-staging_core-x86_64-Build0047.0001-Media.iso',
        params => {
            arch    => "x86_64",
            build   => "0047.0001",
            distri  => "openSUSE",
            flavor  => "staging_core",
            version => "Factory",
        },
    },

    {
        iso => 'openSUSE-FTT-KDE-Live-x86_64-Snapshot20140402-Media.iso',
        params => {
            version => 'FTT',
            distri => 'openSUSE',
            flavor => 'KDE-Live',
            build => '20140402',
            arch => 'x86_64',
        },
    }
);

for my $t (@testdata) {
    my $params = openqa::distri::opensuse::parse_iso($t->{iso});
    if ($t->{params}) {
        is_deeply($params, $t->{params}, $t->{iso});
    } else {
        ok(!defined $params, $t->{iso});
    }
}
