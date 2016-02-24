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
    unshift @INC, 'lib';
}

use Mojo::Base -strict;
use Test::More 'no_plan';
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;
use Data::Dumper;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

my $t = Test::Mojo->new('OpenQA::WebAPI');

# we don't want to test javascript here, so we just test the javascript code
# List with no login
my $get = $t->get_ok('/tests')->status_is(200);
$get->content_like(qr/is_operator = false;/, "test list rendered without is_operator");

# List with an authorized user
$test_case->login($t, 'percival');
$get = $t->get_ok('/tests')->status_is(200);
$get->content_like(qr/is_operator = true;/, "test list rendered with is_operator");

# List with a not authorized user
$test_case->login($t, 'lancelot', email => 'lancelot@example.com');
$get = $t->get_ok('/tests')->status_is(200);
$get->content_like(qr/is_operator = false;/, "test list rendered without is_operator");

# now the same for scheduled jobs
$t->delete_ok('/logout')->status_is(302);

# List with no login
$get = $t->get_ok('/tests')->status_is(200);
$get->element_exists_not('#scheduled #job_99928 a.cancel');

# List with an authorized user
$test_case->login($t, 'percival');
$get = $t->get_ok('/tests')->status_is(200);
$get->element_exists('#scheduled #job_99928 a.cancel');

# List with a not authorized user
$test_case->login($t, 'lancelot', email => 'lancelot@example.com');
$get = $t->get_ok('/tests')->status_is(200);
$get->element_exists_not('#scheduled #job_99928 a.cancel');
