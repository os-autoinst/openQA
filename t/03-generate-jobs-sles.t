#!/usr/bin/perl -w

BEGIN { unshift @INC, 'lib', 'lib/OpenQA/modules'; }

use strict;
use Data::Dump qw/pp dd/;
use openqa::distri::sles qw(generate_jobs);

use Test::More;

my @testdata = (
    {
        iso => 'SLE-12-Server-DVD-x86_64-Build0005-Media1.iso',
        params => [
            {
                ARCH     => 'x86_64',
                BUILD    => '0005',
                DESKTOP  => "gnome",
                DISTRI   => "sles",
                DVD      => 1,
                FLAVOR   => "DVD",
                ISO      => "SLE-12-Server-DVD-x86_64-Build0005-Media1.iso",
                ISO_MAXSIZE => 4_700_372_992,
                PRIO     => 45,
                QEMUCPUS => 2,
                TEST     => 'default',
                VERSION  => 12,
            },
            {
                ARCH        => 'x86_64',
                BUILD       => '0005',
                DESKTOP     => "gnome",
                DISTRI      => "sles",
                DVD         => 1,
                FLAVOR      => "DVD",
                INSTALLONLY => 1,
                ISO         => "SLE-12-Server-DVD-x86_64-Build0005-Media1.iso",
                ISO_MAXSIZE => 4_700_372_992,
                PRIO        => 45,
                QEMUCPU     => "qemu64",
                TEST        => 'uefi',
                UEFI        => 1,
                VERSION     => 12,
            },
        ]
    },
);

for my $t (@testdata) {
    my $params = openqa::distri::sles->generate_jobs({}, iso => $t->{iso});
    if ($t->{params}) {
        SKIP: {
            skip "number of jobs does not match" unless is(scalar  @{$t->{params}}, scalar @$params);

            for my $i (0 .. @{$t->{params}}) {
                is_deeply($params->[$i], $t->{params}->[$i]);
            }
        }
    } else {
        ok(!defined $params, $t->{iso});
    }
}

done_testing;
