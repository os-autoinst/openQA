#!/usr/bin/perl -w

BEGIN { unshift @INC, 'lib', 'lib/OpenQA/modules'; }

use strict;
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
