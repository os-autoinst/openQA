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

use Test::More tests => 4;

# We need the fixtures so we have job templates
my $schema = OpenQA::Test::Database->new->create;

# create Test DBus bus and service for fake WebSockets
my $ipc = OpenQA::IPC->ipc('', 1);
my $ws  = OpenQA::WebSockets->new();
my $sh  = OpenQA::Scheduler->new();

# check we have no gru download tasks to start with
my @tasks = $schema->resultset("GruTasks")->search({taskname => 'download_asset'});
ok(scalar @tasks == 0);

# check a regular ISO post creates the expected number of jobs
my $ids = OpenQA::Scheduler::Scheduler::job_schedule_iso(DISTRI => 'opensuse', VERSION => '13.1', FLAVOR => 'DVD', ARCH => 'i586', ISO => 'openSUSE-13.1-DVD-i586-Build0091-Media.iso');
ok($ids == 10);

# Schedule download of an existing ISO; gru task should not be created
$ids = OpenQA::Scheduler::Scheduler::job_schedule_iso(DISTRI => 'opensuse', VERSION => '13.1', FLAVOR => 'DVD', ARCH => 'i586', ISO_URL => 'openSUSE-13.1-DVD-i586-Build0091-Media.iso');
@tasks = $schema->resultset("GruTasks")->search({taskname => 'download_asset'});
ok(scalar @tasks == 0);

# Schedule download of a non-existing ISO; gru task should be created
$ids = OpenQA::Scheduler::Scheduler::job_schedule_iso(DISTRI => 'opensuse', VERSION => '13.1', FLAVOR => 'DVD', ARCH => 'i586', ISO_URL => 'nonexistent.iso');
@tasks = $schema->resultset("GruTasks")->search({taskname => 'download_asset'});
ok(scalar @tasks == 1);
