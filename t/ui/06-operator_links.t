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
    unshift @INC, 'lib', 'lib/OpenQA';
}

use Mojo::Base -strict;
use Test::More tests => 12;
use Test::Mojo;
use OpenQA::Test::Case;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

my $t = Test::Mojo->new('OpenQA');

# List with no login
my $get = $t->get_ok('/tests')->status_is(200);
$get->element_exists_not('#results #job_99928 .cancel a');
$get->element_exists_not('#results #job_99946 a[data-method=post] img[alt=restart]');

# List with an authorized user
$test_case->login($t, 'percival');
$get = $t->get_ok('/tests')->status_is(200);
$get->element_exists('#results #job_99928 .cancel a');
$get->element_exists('#results #job_99946 a[data-method=post] img[alt=restart]');

# List with a not authorized user
$test_case->login($t, 'lancelot', email => 'lancelot@example.com');
$get = $t->get_ok('/tests')->status_is(200);
$get->element_exists_not('#results #job_99928 .cancel a');
$get->element_exists_not('#results #job_99946 a[data-method=post] img[alt=restart]');

done_testing();
