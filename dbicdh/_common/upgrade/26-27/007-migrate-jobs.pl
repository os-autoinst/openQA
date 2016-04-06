#!/usr/bin/env perl

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

    my $jts = $schema->resultset("JobTemplates");
    while (my $jt = $jts->next) {
        my $settings = {};
        for my $s ($jt->machine->settings->all) {
            $settings->{$s->key} = $s->value;
        }
        $settings->{DISTRI}  = $jt->product->distri;
        $settings->{VERSION} = $jt->product->version if $jt->product->version ne '*';
        $settings->{FLAVOR}  = $jt->product->flavor;
        $settings->{ARCH}    = $jt->product->arch;
        for my $s ($jt->test_suite->settings->all) {
            # stuff defined in both the machine and the test_suite will actually be "wrong"
            delete $settings->{$s->key};
        }

        my $searches = {'me.test' => $jt->test_suite->name};
        my @joins;

        for my $c (1 .. 20) {
            my $key = (sort keys %$settings)[0];
            last unless $key;
            my $value = delete $settings->{$key};
            push(@joins, 'settings');
            my $where = "settings_$c";
            $where = 'settings' if ($c == 1);
            $searches->{"$where.key"}   = $key;
            $searches->{"$where.value"} = $value;
        }
        #print $jt->machine->name, " ", $jt->product->name, " ", $jt->test_suite->name, " ", join(',', map { $_->id } $schema->resultset("Jobs")->search($searches, { join => \@joins })->all), " ", $jt->group_id, "\n";
        $schema->resultset("Jobs")->search($searches, {join => \@joins})->update_all({group_id => $jt->group_id});
    }
  }
