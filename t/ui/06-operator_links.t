# Copyright 2014-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '20';
use OpenQA::Test::Case;
use OpenQA::Test::Database;
use OpenQA::SeleniumTest;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data(fixtures_glob => '03-users.pl');
driver_missing unless my $driver = call_driver;

my $t = Test::Mojo->new('OpenQA::WebAPI');

# we don't want to test javascript here, so we just test the javascript code
note 'List with no login';
$t->get_ok('/tests')->status_is(200)->content_like(qr/is_operator = false;/, 'test list rendered without is_operator');
note 'List with an authorized user';
$test_case->login($t, 'percival');
$t->get_ok('/tests')->status_is(200)->content_like(qr/is_operator = true;/, 'test list rendered with is_operator');
note 'List with a not authorized user';
$test_case->login($t, 'lancelot', email => 'lancelot@example.com');
$t->get_ok('/tests')->status_is(200)->content_like(qr/is_operator = false;/, 'test list rendered without is_operator');
$t->delete_ok('/logout')->status_is(302);
note 'List with an authorized user (presence of cancel button already checked in 01-list.t)';
$test_case->login($t, 'percival');
$t->get_ok('/tests')->status_is(200);
note 'List with a not authorized user';
$test_case->login($t, 'lancelot', email => 'lancelot@example.com');
$t->get_ok('/tests')->status_is(200);
note 'operator has access to part of admin menu';
$driver->title_is('openQA', 'on main page');
$driver->find_element_by_link_text('Login')->click();
$driver->title_is('openQA', 'back on main page');
is($driver->find_element('#user-action a')->get_text(), 'Logged in as Demo', "logged in as demo");
note 'now hack ourselves to be just operator - this is stupid procedure, but we do not have API for user management';
$driver->find_element('#user-action a')->click();
$driver->find_element_by_link_text('Users')->click;
$driver->execute_script('$("#users").off("change")');
$driver->execute_script(
    '$("#users").on("change", "input[name=\"role\"]:radio", function() {$(this).parent("form").submit();})');
$driver->find_element_by_xpath('//tr[./td[@class="nick" and text()="Demo"]]/td[@class="role"]//label[2]')->click;
note 'refresh and return to admin pages';
$driver->refresh;
$driver->get($driver->get_current_url =~ s/users//r);

$driver->find_element('#user-action a')->click();
note 'we should see test templates, groups, machines';
for my $item ('Medium types', 'Machines', 'Workers', 'Assets', 'Scheduled products') {
    ok($driver->find_element_by_link_text($item), "can see $item");
}
note 'we should not see users, audit';
for my $item ('Users', 'Needles', 'Audit log') {
    ok(!scalar @{$driver->find_elements($item, 'link_text')}, "can not see $item");
}

kill_driver();
done_testing();
