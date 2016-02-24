#!/usr/bin/env perl -w

# Copyright (C) 2016 Red Hat
# Copyright (C) 2016 SUSE LLC
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

# Test job creation with job_create_iso.

BEGIN {
    unshift @INC, 'lib';
}

use strict;
use OpenQA::IPC;
use OpenQA::Scheduler;
use OpenQA::WebSockets;
use OpenQA::Test::Database;
use Net::DBus;
use Net::DBus::Test::MockObject;

use Test::Output;
use Test::More 'no_plan';

# We need the fixtures so we have job templates
my $schema = OpenQA::Test::Database->new->create;

# create Test DBus bus and service for fake WebSockets
my $ipc = OpenQA::IPC->ipc('', 1);
my $ws  = OpenQA::WebSockets->new();
my $sh  = OpenQA::Scheduler->new();


my @tasks;
@tasks = $schema->resultset("GruTasks")->search({taskname => 'download_asset'});
is(scalar @tasks, 0, 'we have no gru download tasks to start with');

my $warning = qr/START_AFTER_TEST=.* not found - check for typos and dependency cycles/;
stderr_like { @tasks = OpenQA::Scheduler::Scheduler::job_schedule_iso(DISTRI => 'opensuse', VERSION => '13.1', FLAVOR => 'DVD', ARCH => 'i586', ISO => 'openSUSE-13.1-DVD-i586-Build0091-Media.iso') } $warning, 'warnings expected about test dependencies';
is(scalar @tasks, 10, 'a regular ISO post creates the expected number of jobs');

# Schedule download of an existing ISO
my $ids;
stderr_like { $ids = OpenQA::Scheduler::Scheduler::job_schedule_iso(DISTRI => 'opensuse', VERSION => '13.1', FLAVOR => 'DVD', ARCH => 'i586', ISO_URL => 'openSUSE-13.1-DVD-i586-Build0091-Media.iso') } $warning, 'expected warnings';
is($schema->resultset("GruTasks")->search({taskname => 'download_asset'}), 0, 'gru task should not be created');

# Schedule download of a non-existing ISO
stderr_like { $ids = OpenQA::Scheduler::Scheduler::job_schedule_iso(DISTRI => 'opensuse', VERSION => '13.1', FLAVOR => 'DVD', ARCH => 'i586', ISO_URL => 'nonexistent.iso') } $warning, 'expected warnings';
is($schema->resultset("GruTasks")->search({taskname => 'download_asset'}), 1, 'gru task should be created');
