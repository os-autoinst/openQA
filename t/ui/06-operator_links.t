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
use Test::More;
use Test::Mojo;
use OpenQA::Test::Case;
use Data::Dumper;
use t::ui::PhantomTest;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

my $t = Test::Mojo->new('OpenQA');
my $driver = t::ui::PhantomTest::call_phantom();
if ($driver) {
    plan tests => 17;
}
else {
    plan skip_all => 'Install phantomjs to run these tests';
    exit(0);
}

my $baseurl = $driver->get_current_url();
# we don't want to test javascript here, so we just test the javascript code
# List with no login
my $get = $t->get_ok('/tests')->status_is(200);
$get->content_like(qr/renderTestsList\([^)]*,\s*0\s*,/, "test list rendered without is_operator");

# List with an authorized user
$test_case->login($t, 'percival');
$get = $t->get_ok('/tests')->status_is(200);
$get->content_like(qr/renderTestsList\([^)]*,\s*1\s*,/, "test list rendered with is_operator");

# List with a not authorized user
$test_case->login($t, 'lancelot', email => 'lancelot@example.com');
$get = $t->get_ok('/tests')->status_is(200);
$get->content_like(qr/renderTestsList\([^)]*,\s*0\s*,/, "test list rendered without is_operator");

# now the same for scheduled jobs
$t->delete_ok('/logout')->status_is(302);

# List with no login
ok($driver->get($baseurl . 'tests'));
ok(!@{$driver->find_elements('#scheduled #job_99928 a.api-cancel', 'css')}, 'cancel does not exists for anonymous');

# List with an authorized user
$test_case->login($t, 'percival');
ok($driver->get($baseurl . 'tests'));
ok($driver->find_element('#scheduled #job_99928 a.api-cancel', 'css'), 'cancel does exists for operator');

# List with a not authorized user
$test_case->login($t, 'lancelot', email => 'lancelot@example.com');
ok($driver->get($baseurl . 'tests'));
ok(!@{$driver->find_elements('#scheduled #job_99928 a.api-cancel', 'css')}, 'cancel does not exists for unauthorized');

t::ui::PhantomTest::kill_phantom();
done_testing();
