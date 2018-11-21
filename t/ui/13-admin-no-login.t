#! /usr/bin/perl

# Copyright (C) 2018 SUSE LLC
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

use Mojo::Base -strict;

BEGIN {
    unshift @INC, 'lib';
    $ENV{OPENQA_TEST_IPC} = 1;
}

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;
use OpenQA::SeleniumTest;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

plan skip_all => $OpenQA::SeleniumTest::drivermissing unless my $driver = call_driver();

# First page without login
$driver->title_is("openQA");

# Test suites without login
is $driver->get('/admin/test_suites'), 1, 'opened test suites';
$driver->title_is('openQA: Test suites');
like $driver->find_element('#test-suites tbody tr.odd td')->get_text(),  qr/textmode/, 'first entry';
like $driver->find_element('#test-suites tbody tr.even td')->get_text(), qr/kde/,      'second entry';
like $driver->find_element('#test-suites tbody tr.even td:nth-child(3)')->get_text(),
  qr/Simple kde test, before advanced_kde/,
  'second entry has a description';
like $driver->find_element('#test-suites tbody tr:last-child td')->get_text(), qr/advanced_kde/, 'last entry';

kill_driver();
done_testing();
