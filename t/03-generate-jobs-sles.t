#!/usr/bin/perl -w

use strict;
use Data::Dump qw/pp dd/;
use FindBin;
use lib $FindBin::Bin.'/../www/cgi-bin/modules';
use openqa::distri::sles qw(generate_jobs);

use Test::More tests => 1;

my @testdata = (
    {
        iso => 'SLE-12-Server-DVD-x86_64-Build0005-Media1.iso',
        params => [
            {
                DESKTOP  => "gnome",
                DISTRI   => "sles",
                DVD      => 1,
                FLAVOR   => "DVD",
                ISO      => "SLE-12-Server-DVD-x86_64-Build0005-Media1.iso",
                NAME     => "SLES-12-DVD-x86_64-Build0005-default",
                PRIO     => 45,
                QEMUCPUS => 2,
                VERSION  => 12,
            },
            {
                DESKTOP     => "gnome",
                DISTRI      => "sles",
                DVD         => 1,
                FLAVOR      => "DVD",
                INSTALLONLY => 1,
                ISO         => "SLE-12-Server-DVD-x86_64-Build0005-Media1.iso",
                NAME        => "SLES-12-DVD-x86_64-Build0005-uefi",
                PRIO        => 45,
                QEMUCPU     => "qemu64",
                UEFI        => 1,
                VERSION     => 12,
            },
        ]
    },
);

for my $t (@testdata) {
    my $params = openqa::distri::sles->generate_jobs(iso => $t->{iso});
    if ($t->{params}) {
        is_deeply($params, $t->{params}) or diag("failed params: ". pp($params));
    } else {
        ok(!defined $params, $t->{iso});
    }
}
