#!/usr/bin/perl -w

BEGIN { unshift @INC, 'lib', 'lib/OpenQA/modules'; }

use strict;
use Data::Dump qw/pp dd/;
use openqa::distri::opensuse qw(parse_iso);

use Test::More tests => 12;

my @testdata = (
    {
        iso => "openSUSE-13.1-DVD-Biarch-i586-x86_64-Build0067-Media.iso",
        params => {
            'distri' => 'openSUSE',
            'arch' => 'i586-x86_64',
            'version' => '13.1',
            'build' => 'Build0067',
            'flavor' => 'DVD-Biarch'
        },
    },
    {
        iso => "openSUSE-13.1-Promo-DVD-OpenSourcePress-i586-x86_64-Build0002-Media.iso",
        params => {
            'distri' => 'openSUSE',
            'arch' => 'i586-x86_64',
            'version' => '13.1',
            'build' => 'Build0002',
            'flavor' => 'Promo-DVD-OpenSourcePress'
        },
    },
    {
        iso => "openSUSE-Factory-DVD-x86_64-Build0725-Media.iso",
        params => {
            'distri' => 'openSUSE',
            'arch' => 'x86_64',
            'version' => 'Factory',
            'build' => 'Build0725',
            'flavor' => 'DVD'
        },
    },
    {
        iso => "openSUSE-13.1-KDE-Live-x86_64-Build0034-Media.iso",
        params => {
            'distri' => 'openSUSE',
            'arch' => 'x86_64',
            'version' => '13.1',
            'build' => 'Build0034',
            'flavor' => 'KDE-Live'
        },
    },
    {
        iso => "openSUSE-13.1-GNOME-Live-i586-Build0045-Media.iso",
        params => {
            'distri' => 'openSUSE',
            'arch' => 'i586',
            'version' => '13.1',
            'build' => 'Build0045',
            'flavor' => 'GNOME-Live'
        },
    },
    {
        iso => "openSUSE-13.1-NET-i586-Build0042-Media.iso",
        params => {
            'distri' => 'openSUSE',
            'arch' => 'i586',
            'version' => '13.1',
            'build' => 'Build0042',
            'flavor' => 'NET'
        },
    },
    {
        iso => "openSUSE-13.1-Promo-DVD-x86_64-Build0066-Media.iso",
        params => {
            'distri' => 'openSUSE',
            'arch' => 'x86_64',
            'version' => '13.1',
            'build' => 'Build0066',
            'flavor' => 'Promo-DVD'
        },
    },
    {
        iso => "openSUSE-13.1-Rescue-CD-i686-Build0066-Media.iso",
        params => {
            'distri' => 'openSUSE',
            'arch' => 'i686',
            'version' => '13.1',
            'build' => 'Build0066',
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
            build   => "Build0047.0001",
            distri  => "openSUSE",
            flavor  => "staging_core",
            version => "Factory",
        },
    },
);

for my $t (@testdata) {
    my $params = openqa::distri::opensuse::parse_iso($t->{iso});
    if ($t->{params}) {
        is_deeply($params, $t->{params}, $t->{iso});
    } else {
        ok(!defined $params, $t->{iso});
    }
}
