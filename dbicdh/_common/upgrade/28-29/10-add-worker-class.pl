#!/usr/bin/perl -w

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

use strict;
use warnings;

sub {

    my $schema = shift;

    # set worker class on all machines

    # mapping of well known machiens. For all other we just use qemu_$machine_name.
    # The admin has to change that later but at least jobs won't get
    # created without any class then
    my %worker_name_class_mapping = (
        '32bit' => 'qemu_i586',
        "64bit" => 'qemu_x86_64',
        "uefi" => 'qemu_x86_64',
        "uefi-suse" => 'qemu_x86_64',
        "Laptop_32" => 'qemu_i586',
        "Laptop_64" => 'qemu_x86_64',
        "USBboot_32" => 'qemu_i586',
        "USBboot_64" => 'qemu_x86_64',
        "smp_32" => 'qemu_i586',
        "smp_64" => 'qemu_x86_64',
    );
    my $workers_with_class = $schema->resultset('Machines')->search({ 'settings.key' => 'WORKER_CLASS'},{ columns => ['id'], join => ['settings']})->as_query;
    my $rs = $schema->resultset('Machines')->search({ id => {  -not_in => $workers_with_class } },);
    while (my $r = $rs->next()) {
        my $class;
        if (exists $worker_name_class_mapping{$r->name}) {
            $class = $worker_name_class_mapping{$r->name};
        }
        else {
            $class = 'qemu_'.$r->name;
        }
        printf "%s %s: added %s\n", $r->id, $r->name, $class;
        my $result = $r->settings->create({key => 'WORKER_CLASS', value => $class});
        unless ($result) {
            warn "failed to set WORKER_CLASS on worker $r->id";
        }
    }

    # set a worker class on all scheduled jobs so they won't suddely get
    # dispatched to any worker.
    my $jobs_with_class = $schema->resultset('Jobs')->search({ 'settings.key' => 'WORKER_CLASS'},{ columns => ['id'], join => ['settings']})->as_query;
    $rs = $schema->resultset('Jobs')->search({ id => {  -not_in => $jobs_with_class }, state => 'scheduled' },);
    while (my $r = $rs->next()) {
        my $arch = $r->settings->find({key => 'ARCH'});
        next unless $arch;
        $arch = $arch->value;
        my $result = $schema->resultset('JobSettings')->create({ job_id => $r->id, key => 'WORKER_CLASS', value => 'qemu_'.$arch});
        unless ($result) {
            warn "failed to set WORKER_CLASS on job $r->id";
            next;
        }
        printf "%s %s: added %s\n", $r->id, $r->name, $arch;
    }
  }
