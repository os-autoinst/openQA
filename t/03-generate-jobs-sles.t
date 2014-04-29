#!/usr/bin/env perl -w

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
use Data::Dump qw/pp dd/;
use openqa::distri::sles qw(generate_jobs);

use Test::Mojo;
use Test::More;

my $app = Test::Mojo->new('OpenQA')->app;

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
    my $params = openqa::distri::sles->generate_jobs($app, iso => $t->{iso});
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
