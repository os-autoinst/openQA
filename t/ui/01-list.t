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

BEGIN {
  unshift @INC, 'lib', 'lib/OpenQA/modules';
}

use Mojo::Base -strict;
use Test::More tests => 42;
use Test::Mojo;
use OpenQA::Test::Case;

OpenQA::Test::Case->new->init_data;

my $t = Test::Mojo->new('OpenQA');

#
# List with no parameters
#
my $get = $t->get_ok('/tests')->status_is(200);
$get->content_like(qr/Test results/i, 'result list is there');

# Test 99946 is successful (30/0/1)
$get->element_exists('#results #job_99946 .extra');
$get->text_is('#results #job_99946 .extra span' => 'textmode');
$get->text_is('#results #job_99946 td:nth-child(11) .overview_passed' => '30');
$get->text_is('#results #job_99946 td:nth-child(13) .overview_failed' => '1');

# Test 99963 is still running
ok($get->tx->res->dom->at('#results #job_99963 td.link a') eq '<a href="/tests/99963">testing</a>');

# Test 99928 is scheduled (so can be canceled)
$get->text_is('#results #job_99928 td.link a' => 'scheduled');
$get->element_exists('#results #job_99928 .cancel');

# Test 99938 failed, so it should be displayed in red
$get->text_is('#results #job_99938 .extra .overview_failed' => 'doc');


# Test 99937 is too old to be displayed by default
$get->element_exists_not('#results #job_99937');

# Test 99926 is displayed
$get->element_exists('#results #job_99926');
$get->text_is('#results #job_99926 .extra .overview_incomplete' => 'minimalx');

$get = $t->get_ok('/tests' => form => {ignore_incomplete => 1})->status_is(200);

# Test 99926 not displayed anymore
$get->element_exists_not('#results #job_99926');

#
# List with a limit of 200h
#
$get = $t->get_ok('/tests' => form => {hoursfresh => 200})->status_is(200);

# Test 99937 is displayed now
$get->element_exists('#results #job_99937');
$get->text_is('#results #job_99937 td:nth-child(11) .overview_passed' => '48');

#
# Testing the default scope (relevant)
#
$get = $t->get_ok('/tests')->status_is(200);
$get->content_like(qr/Test results/i, 'result list is there');
$get->element_exists('#results #job_99946');
$get->element_exists('#results #job_99963');
# Test 99945 is not longer relevant (replaced by 99946)
$get->element_exists_not('#results #job_99945');
# Test 99962 is still relevant (99963 is still running)
$get->element_exists('#results #job_99962');

#
# Testing the scope current
#
$get = $t->get_ok('/tests' => form => {scope => 'current'})->status_is(200);
$get->content_like(qr/Test results/i, 'result list is there');
$get->element_exists('#results #job_99946');
$get->element_exists('#results #job_99963');
# Test 99945 is not current (replaced by 99946)
$get->element_exists_not('#results #job_99945');
# Test 99962 is not current (replaced by 99963)
$get->element_exists_not('#results #job_99962');

#
# Testing with no scope
#
$get = $t->get_ok('/tests' => form => {scope => ''})->status_is(200);
$get->content_like(qr/Test results/i, 'result list is there');
$get->element_exists('#results #job_99946');
$get->element_exists('#results #job_99963');
$get->element_exists('#results #job_99945');
$get->element_exists('#results #job_99962');

done_testing();
