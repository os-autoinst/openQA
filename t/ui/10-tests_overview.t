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
use Date::Format 'time2str';
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;
use OpenQA::SeleniumTest;
use OpenQA::Jobs::Constants;

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

    # add a previous job to 99937 (opensuse-13.1-DVD-i586-kde@32bit)
    # (for subtest 'filtering does not reveal old jobs')
    $jobs->create(
        {
            id         => 99920,
            group_id   => 1001,
            priority   => 50,
            result     => OpenQA::Jobs::Constants::FAILED,
            state      => OpenQA::Jobs::Constants::DONE,
            TEST       => 'kde',
            VERSION    => '13.1',
            BUILD      => '0091',
            ARCH       => 'i586',
            MACHINE    => '32bit',
            DISTRI     => 'opensuse',
            FLAVOR     => 'DVD',
            t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 36000, 'UTC'),
            t_started  => time2str('%Y-%m-%d %H:%M:%S', time - 72000, 'UTC'),
            t_created  => time2str('%Y-%m-%d %H:%M:%S', time - 72000, 'UTC'),
            modules    => [
                {
                    script   => 'tests/foo/bar.pm',
                    category => 'foo',
                    name     => 'bar',
                    result   => 'failed',
                },
            ],
        });
    $jobs->find(99946)->update({result => OpenQA::Jobs::Constants::FAILED});
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
$driver->find_element('#filter-panel .card-header')->click();
$driver->find_element_by_id('filter-todo')->click();
$driver->find_element_by_id('filter-passed')->click();
$driver->find_element_by_id('filter-failed')->click();
$driver->find_element('#filter-form button')->click();
$driver->find_element_by_id('res_DVD_x86_64_doc');
my @filtered_out = $driver->find_elements('#res_DVD_x86_64_kde', 'css');
is(scalar @filtered_out, 0, 'result filter correctly applied');

# Test whether all URL parameter are passed correctly
my $url_with_escaped_parameters
  = $baseurl . 'tests/overview?arch=&modules=&distri=opensuse&build=0091&version=Staging%3AI&groupid=1001';
$driver->get($url_with_escaped_parameters);
$driver->find_element('#filter-panel .card-header')->click();
$driver->find_element('#filter-form button')->click();
is($driver->get_current_url(), $url_with_escaped_parameters . '#', 'escaped URL parameters are passed correctly');

# Test failed module info async update
$driver->get($baseurl . 'tests/overview?distri=opensuse&version=13.1&build=0091&groupid=1001');
my $fmod = $driver->find_elements('.failedmodule', 'css')->[1];
$driver->mouse_move_to_location(element => $fmod, xoffset => 8, yoffset => 8);
wait_for_ajax;
like($driver->find_elements('.failedmodule', 'css')->[1]->get_attribute('href'),
    qr/\/kate\/1$/, 'ajax update failed module step');

my @descriptions = $driver->find_elements('td.name a', 'css');
is(scalar @descriptions, 2, 'only test suites with description content are shown as links');
$descriptions[0]->click();
is($driver->find_element('.popover-header')->get_text, 'kde', 'description popover shows content');

# Test bug status
my @closed_bugs = $driver->find_elements('#bug-99937 .bug_closed', 'css');
is(scalar @closed_bugs, 1, 'closed bug correctly shown');

my @open_bugs = $driver->find_elements('#bug-99946 .label_bug', 'css');
@closed_bugs = $driver->find_elements('#bug-99946 .bug_closed', 'css');
is(scalar @open_bugs,   1, 'open bug correctly shown, and only once despite the 2 comments');
is(scalar @closed_bugs, 0, 'open bug not shown as closed bug');

sub check_build_0091_defaults {
    element_visible('#flavor_DVD_arch_i586',        qr/i586/);
    element_visible('#flavor_DVD_arch_x86_64',      qr/x86_64/);
    element_visible('#flavor_GNOME-Live_arch_i686', qr/i686/);
    element_visible('#flavor_NET_arch_x86_64',      qr/x86_64/);
}

subtest 'filtering by architecture' => sub {
    $driver->get('/tests/overview?distri=opensuse&version=13.1&build=0091');

    subtest 'by default, all archs for all flavors present' => sub {
        check_build_0091_defaults;
    };

    subtest 'filter for specific archs' => sub {
        $driver->find_element('#filter-panel .card-header')->click();
        $driver->find_element('#filter-arch')->send_keys('i586,i686');
        $driver->find_element('#filter-panel .btn-default')->click();

        element_visible('#flavor_DVD_arch_i586', qr/i586/);
        element_not_present('#flavor_DVD_arch_x86_64');
        element_visible('#flavor_GNOME-Live_arch_i686', qr/i686/);
        element_not_present('#flavor_NET_arch_x86_64');
    };
};

subtest 'filtering by test' => sub {
    $driver->get('/tests/overview?test=textmode');

    my @rows = $driver->find_elements('#content tbody tr');
    is(scalar @rows, 1, 'exactly one row present');
    like($rows[0]->get_text(), qr/textmode/, 'test is textmode');
    is(
        OpenQA::Test::Case::trim_whitespace($driver->find_element('#summary .card-header')->get_text()),
        'Overall Summary of opensuse 13.1 build 0092',
        'summary states "opensuse 13.1" although no explicit search params',
    );
};

subtest 'filtering by distri' => sub {
    subtest 'no distri filter yields everything' => sub {
        $driver->get('/tests/overview?version=13.1&build=0091');
        check_build_0091_defaults;
    };

    subtest 'distri filters are ORed' => sub {
        $driver->get('/tests/overview?distri=foo&distri=opensuse&distri=bar&version=13.1&build=0091');
        check_build_0091_defaults;
        is(
            OpenQA::Test::Case::trim_whitespace($driver->find_element('#summary .card-header b')->get_text()),
            'foo/opensuse/bar 13.1',
            'filter also visible in summary'
        );
    };

    subtest 'everything filtered out' => sub {
        $driver->get('/tests/overview?distri=foo&distri=bar&version=13.1&build=0091');
        element_not_present('#flavor_DVD_arch_i586');
        element_not_present('#flavor_DVD_arch_x86_64');
        element_not_present('#flavor_GNOME-Live_arch_i686');
        element_not_present('#flavor_NET_arch_x86_64');
    };
};

subtest 'filtering does not reveal old jobs' => sub {
    $driver->get('/tests/overview?arch=&result=failed&distri=opensuse&version=13.1&build=0091&groupid=1001');
    is($driver->find_element('#summary .badge-danger')->get_text(), '1', 'filtering for failures gives only one job');
    is(scalar @{$driver->find_elements('#res-99946')},              1,   'textmode job still shown');
    is(scalar @{$driver->find_elements('#res-99920')},              0,   'and old kde job not revealed');

    $driver->get('/tests/overview?arch=&failed_modules=zypper_up&distri=opensuse&version=13.1&build=0091&groupid=1001');
    is($driver->find_element('#summary .badge-danger')->get_text(),
        '1', 'filtering for failed modules works for latest job');
    is(scalar @{$driver->find_elements('#res-99946')}, 1, 'textmode job matches failed modules filter');

    $driver->get('/tests/overview?arch=&failed_modules=bar&distri=opensuse&version=13.1&build=0091&groupid=1001');
    is($driver->find_element('#summary .badge-danger')->get_text(),
        '0', 'filtering for failed modules does not reveal old job');
};

subtest 'filtering by module' => sub {
    my $module            = 'kate';
    my $JOB_ICON_SELECTOR = 'td[id^="res_DVD_"]';
    my $result            = 'failed';

    subtest "jobs containing the module with any result are present" => sub {
        my $number_of_found_jobs = 3;
        $driver->get("/tests/overview?arch=&distri=opensuse&modules=$module");
        my @jobs = $driver->find_elements($JOB_ICON_SELECTOR);
        # Assert that all the jobs with the specified module are shown in the results
        is(scalar @jobs, $number_of_found_jobs, "$number_of_found_jobs jobs with \"$module\" module found");
        element_visible('#res_DVD_i586_kde');
        element_visible('#res_DVD_x86_64_kde');
        element_visible('#res_DVD_x86_64_doc');
    };

    subtest "jobs containing the module with the specified result are present" => sub {
        my $number_of_found_jobs = 1;
        $driver->get("/tests/overview?arch=&distri=opensuse&modules=$module&modules_result=$result");
        my @jobs = $driver->find_elements($JOB_ICON_SELECTOR);
        # Assert that all the jobs with the specified module and result are shown in the results
        is(scalar @jobs, $number_of_found_jobs, "$number_of_found_jobs jobs with \"$module\" module found");
        element_visible('#res_DVD_i586_kde');
    };
    subtest "jobs containing all the modules with the specified result are present" => sub {
        my $number_of_found_jobs = 4;
        $driver->get("/tests/overview?arch=&distri=opensuse&modules_result=$result");
        my @jobs = $driver->find_elements($JOB_ICON_SELECTOR);
        # Assert that all the jobs with the specified result are shown in the results
        is(scalar @jobs, $number_of_found_jobs,
            "$number_of_found_jobs jobs where modules with \"$result\" result found");
        element_visible('#res_DVD_i586_kde');
        element_visible('#res_DVD_x86_64_kde');
        element_visible('#res_DVD_i586_textmode');
        element_visible('#res_DVD_x86_64_doc');
    };
    subtest "jobs containing all the modules separated by comma are present" => sub {
        my $modules              = 'kate,zypper_up';
        my $number_of_found_jobs = 2;
        $driver->get("/tests/overview?arch=&distri=opensuse&modules=$modules&modules_result=$result");
        my @jobs = $driver->find_elements($JOB_ICON_SELECTOR);
        # Assert that all the jobs with the specified modules and result are shown in the results
        is(scalar @jobs, $number_of_found_jobs, "$number_of_found_jobs jobs with \"$modules\" modules found");
        element_visible('#res_DVD_i586_kde');
        element_visible('#res_DVD_i586_textmode');
    };
};

kill_driver();

done_testing();
