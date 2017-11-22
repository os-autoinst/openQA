# Copyright (C) 2014-2016 SUSE LLC
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
# with this program; if not, see <http://www.gnu.org/licenses/>.

BEGIN {
    unshift @INC, 'lib';
    $ENV{OPENQA_TEST_IPC} = 1;
}

use Mojo::Base -strict;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;
use OpenQA::SeleniumTest;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

sub schema_hook {
    my $schema   = OpenQA::Test::Database->new->create;
    my $comments = $schema->resultset('Comments');
    my $bugs     = $schema->resultset('Bugs');

    $comments->create(
        {
            text    => 'bsc#111111 Python > Perl',
            user_id => 1,
            job_id  => 99937,
        });

    $comments->create(
        {
            text    => 'bsc#222222 D > Perl',
            user_id => 1,
            job_id  => 99946,
        });

    $comments->create(
        {
            text    => 'bsc#222222 C++ > D',
            user_id => 1,
            job_id  => 99946,
        });

    $bugs->create(
        {
            bugid     => 'bsc#111111',
            refreshed => 1,
            open      => 0,
        });

    # add a job result on another machine type to test rendering
    my $jobs = $schema->resultset('Jobs');
    my $new  = $jobs->find(99963)->to_hash->{settings};
    $new->{MACHINE} = 'uefi';
    $new->{_GROUP}  = 'opensuse';
    $jobs->create_from_settings($new);

    # another one with default to have a unambiguous "preferred" machine type
    $new->{TEST}    = 'kde+workarounds';
    $new->{MACHINE} = '64bit';
    $jobs->create_from_settings($new);
}

my $driver = call_driver(\&schema_hook);

unless ($driver) {
    plan skip_all => $OpenQA::SeleniumTest::drivermissing;
    exit(0);
}

$driver->title_is("openQA", "on main page");
my $baseurl = $driver->get_current_url();

# Test initial state of checkboxes and applying changes
$driver->get($baseurl . 'tests/overview?distri=opensuse&version=Factory&build=0048&todo=1&result=passed');
$driver->find_element('#filter-panel .panel-heading')->click();
$driver->find_element_by_id('filter-todo')->click();
$driver->find_element_by_id('filter-passed')->click();
$driver->find_element_by_id('filter-failed')->click();
$driver->find_element('#filter-form button')->click();
$driver->find_element_by_id('res_DVD_x86_64_doc');
my @filtered_out = $driver->find_elements('#res_DVD_x86_64_kde', 'css');
is(scalar @filtered_out, 0, 'result filter correctly applied');

# Test whether all URL parameter are passed correctly
my $url_with_escaped_parameters
  = $baseurl . 'tests/overview?arch=&failed_modules=&distri=opensuse&build=0091&version=Staging%3AI&groupid=1001';
$driver->get($url_with_escaped_parameters);
$driver->find_element('#filter-panel .panel-heading')->click();
$driver->find_element('#filter-form button')->click();
is($driver->get_current_url(), $url_with_escaped_parameters . '#', 'escaped URL parameters are passed correctly');

# Test failed module info async update
$driver->get($baseurl . 'tests/overview?distri=opensuse&version=13.1&build=0091&groupid=1001');
my $fmod = $driver->find_elements('.failedmodule', 'css')->[1];
$driver->mouse_move_to_location(element => $fmod, xoffset => 8, yoffset => 8);
wait_for_ajax;
like($driver->find_elements('.failedmodule a', 'css')->[1]->get_attribute('href'),
    qr/\/kate\/1$/, 'ajax update failed module step');

my @descriptions = $driver->find_elements('td.name a', 'css');
is(scalar @descriptions, 2, 'only test suites with description content are shown as links');
$descriptions[0]->click();
is($driver->find_element('.popover-title')->get_text, 'kde', 'description popover shows content');

# Test bug status
my @closed_bugs = $driver->find_elements('#bug-99937 .bug_closed', 'css');
is(scalar @closed_bugs, 1, 'closed bug correctly shown');

my @open_bugs = $driver->find_elements('#bug-99946 .label_bug', 'css');
@closed_bugs = $driver->find_elements('#bug-99946 .bug_closed', 'css');
is(scalar @open_bugs,   1, 'open bug correctly shown, and only once despite the 2 comments');
is(scalar @closed_bugs, 0, 'open bug not shown as closed bug');

kill_driver();

done_testing();
