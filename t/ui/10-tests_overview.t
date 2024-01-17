# Copyright 2014-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Date::Format 'time2str';
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '20';
use OpenQA::Test::Case;
use OpenQA::SeleniumTest;
use OpenQA::Jobs::Constants;
use OpenQA::JobDependencies::Constants qw(PARALLEL);

my $test_case = OpenQA::Test::Case->new;
my $schema_name = OpenQA::Test::Database->generate_schema_name;
my $schema = $test_case->init_data(
    schema_name => $schema_name,
    fixtures_glob => '01-jobs.pl 02-workers.pl 04-products.pl 05-job_modules.pl 06-job_dependencies.pl'
);
my $jobs = $schema->resultset('Jobs');

sub prepare_database {
    my $comments = $schema->resultset('Comments');
    my $bugs = $schema->resultset('Bugs');

    $comments->create(
        {
            text => 'bsc#111111 Python > Perl',
            user_id => 1,
            job_id => 99937,
        });

    $comments->create(
        {
            text => 'bsc#222222 D > Perl',
            user_id => 1,
            job_id => 99946,
        });

    $comments->create(
        {
            text => 'bsc#222222 C++ > D',
            user_id => 1,
            job_id => 99946,
        });

    $bugs->create(
        {
            bugid => 'bsc#111111',
            refreshed => 1,
            open => 0,
        });

    # add a job result on another machine type to test rendering
    my $new = $jobs->find(99963)->to_hash->{settings};
    $new->{MACHINE} = 'uefi';
    $new->{_GROUP} = 'opensuse';
    $jobs->create_from_settings($new);

    # another one with default to have a unambiguous "preferred" machine type
    $new->{TEST} = 'kde+workarounds';
    $new->{MACHINE} = '64bit';
    $jobs->create_from_settings($new);

    # add a previous job to 99937 (opensuse-13.1-DVD-i586-kde@32bit)
    # (for subtest 'filtering does not reveal old jobs')
    $jobs->create(
        {
            id => 99920,
            group_id => 1001,
            priority => 50,
            result => OpenQA::Jobs::Constants::FAILED,
            state => OpenQA::Jobs::Constants::DONE,
            TEST => 'kde',
            VERSION => '13.1',
            BUILD => '0091',
            ARCH => 'i586',
            MACHINE => '32bit',
            DISTRI => 'opensuse',
            FLAVOR => 'DVD',
            t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 36000, 'UTC'),
            t_started => time2str('%Y-%m-%d %H:%M:%S', time - 72000, 'UTC'),
            t_created => time2str('%Y-%m-%d %H:%M:%S', time - 72000, 'UTC'),
            modules => [
                {
                    script => 'tests/foo/bar.pm',
                    category => 'foo',
                    name => 'bar',
                    result => 'failed',
                },
            ],
        });
    $jobs->find(99946)->update({result => OpenQA::Jobs::Constants::FAILED});

    # add job for testing job template name
    my $job_hash = {
        id => 99990,
        group_id => 1002,
        priority => 30,
        result => OpenQA::Jobs::Constants::FAILED,
        state => OpenQA::Jobs::Constants::DONE,
        TEST => 'kde_variant',
        VERSION => '13.1',
        BUILD => '0091',
        ARCH => 'x86_64',
        MACHINE => '64bit',
        DISTRI => 'opensuse',
        FLAVOR => 'DVD',
        t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 36000, 'UTC'),
        t_started => time2str('%Y-%m-%d %H:%M:%S', time - 72000, 'UTC'),
        t_created => time2str('%Y-%m-%d %H:%M:%S', time - 72000, 'UTC'),
        settings => [{key => 'JOB_TEMPLATE_NAME', value => 'kde_variant'}, {key => 'TEST_SUITE_NAME', value => 'kde'}],
    };
    $jobs->create($job_hash);
}

prepare_database;

driver_missing unless my $driver = call_driver;
disable_timeout;

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
  = $baseurl
  . 'tests/overview?arch=&flavor=&machine=&test=&modules=&module_re=&group_glob=&not_group_glob=&comment=&distri=opensuse&build=0091&version=Staging%3AI&groupid=1001';
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
disable_bootstrap_animations;
$descriptions[0]->click();
is($driver->find_element('.popover-header')->get_text, 'kde', 'description popover shows content');

# Test bug status
my @closed_bugs = $driver->find_elements('#bug-99937 .bug_closed', 'css');
is(scalar @closed_bugs, 1, 'closed bug correctly shown');

my @open_bugs = $driver->find_elements('#bug-99946 .label_bug', 'css');
@closed_bugs = $driver->find_elements('#bug-99946 .bug_closed', 'css');
is(scalar @open_bugs, 1, 'open bug correctly shown, and only once despite the 2 comments');
is(scalar @closed_bugs, 0, 'open bug not shown as closed bug');

sub check_build_0091_defaults {
    element_visible('#flavor_DVD_arch_i586', qr/i586/);
    element_visible('#flavor_DVD_arch_x86_64', qr/x86_64/);
    element_visible('#flavor_GNOME-Live_arch_i686', qr/i686/);
    element_visible('#flavor_NET_arch_x86_64', qr/x86_64/);
}

subtest 'stacking of parallel children' => sub {
    $driver->get($baseurl . 'tests/overview?groupid=1001&distri=opensuse&version=13.1&build=0091');
    element_visible '#res-99963', undef, undef, 'parallel child not collapsed if parent not present (different group)';
    $driver->get($baseurl . 'tests/overview?build=0091&distri=opensuse&version=13.1');
    element_visible '#res-99963', undef, undef, 'parallel child not collapsed if in other table (different flavor)';
    element_not_present '.toggle-parallel-children', 'parallel parent has not toggle icon';
    $jobs->find(99961)->update({FLAVOR => 'DVD', TEST => 'some-parallel-parent'});
    $driver->refresh;
    my $toggle_button = $driver->find_element('.toggle-parallel-children');
    ok $toggle_button, 'toggle button present' or return;
    element_visible '#res-99963', undef, undef, 'parallel child expanded if parent in same table';
    element_visible '#res-99937', undef, undef, 'job from other architecture expanded as well';
    $toggle_button->click;
    element_hidden '#res-99963', 'parallel child collapsed after clicking stacking icon';
    element_hidden '#res-99937', 'job from other architecture collapsed as well';
    $toggle_button->click;
    element_visible '#res-99963', undef, undef, 'parallel child expanded again';
    element_visible '#res-99937', undef, undef, 'job from other architecture expanded again as well';
    my $collapse_all_button = $driver->find_element('.collapse-all-button');
    ok $toggle_button, 'collapse all button present' or return;
    $toggle_button->click;
    element_hidden '#res-99963', 'parallel child collapsed after clicking "Collapse all" button';
    $jobs->find(99963)->update({state => DONE, result => SOFTFAILED});
    $driver->refresh;
    element_hidden '#res-99963', 'parallel child collapse by default if one of OK_RESULTS';
    my %dep = (parent_job_id => 99764, child_job_id => 99982, dependency => PARALLEL);
    my $another_dependency = $schema->resultset('JobDependencies')->create(\%dep);
    $driver->refresh;
    $another_dependency->delete;
    my @collapse_all_buttons = $driver->find_elements('.collapse-all-button');
    my @expand_all_buttons = $driver->find_elements('.expand-all-button');
    is scalar @collapse_all_buttons, 1, 'exactly one collapse button present';
    is scalar @expand_all_buttons, 1, 'exactly one expand button present';
    return unless @collapse_all_buttons && @expand_all_buttons;
    element_hidden '#res-99937', 'job 99937 hidden in the first place';
    element_visible '#res-99982', undef, undef, 'job 99982 shown in the first place';
    $expand_all_buttons[0]->click;
    element_visible '#res-99937', undef, undef, 'job 99937 expanded via expand all button';
    element_visible '#res-99982', undef, undef, 'job 99982 stays expanded';
    $collapse_all_buttons[0]->click;
    element_hidden '#res-99937', 'job 99937 collapsed via collapse all button';
    element_hidden '#res-99982', 'job 99982 collapsed via collapse all button';
};

subtest 'stacking of cyclic parallel jobs' => sub {
    my %cycle = (parent_job_id => 99963, child_job_id => 99961, dependency => PARALLEL);
    my $cycle = $schema->resultset('JobDependencies')->create(\%cycle);
    $jobs->find(99963)->update({state => RUNNING, result => NONE});
    $driver->refresh;
    $cycle->delete;
    my $toggle_button = $driver->find_element('.toggle-parallel-children');
    ok $toggle_button, 'toggle button present despite cycle (first job takes role of parent)' or return;
    element_visible '#res-99961', undef, undef, 'all parallel jobs expanded (1)';
    element_visible '#res-99963', undef, undef, 'all parallel jobs expanded (2)';
    element_visible '#res-99937', undef, undef, 'job from other architecture expanded as well (1)';
    $toggle_button->click;
    my $find_parent = 'return document.getElementsByClassName("parallel-parent")[0].dataset.parallelParents';
    my $parent_id = $driver->execute_script($find_parent);
    note "job taking role of parent: $parent_id";
    element_hidden($parent_id eq '99963' ? '#res-99961' : '#res-99963'), 'child job collapsed after expanding (1)';
};

$jobs->find(99961)->update({FLAVOR => 'NET', TEST => 'kde'});

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

subtest 'filtering by flavor' => sub {
    $driver->get('/tests/overview?distri=opensuse&version=13.1&build=0091');

    subtest 'by default, all flavors present' => sub {
        check_build_0091_defaults;
    };

    subtest 'filter for specific flavors' => sub {
        $driver->find_element('#filter-panel .card-header')->click();
        $driver->find_element('#filter-flavor')->send_keys('DVD');
        $driver->find_element('#filter-panel .btn-default')->click();

        element_visible('#flavor_DVD_arch_i586', qr/i586/);
        element_visible('#flavor_DVD_arch_x86_64', qr/x86_64/);
        element_not_present('#flavor_GNOME-Live_arch_i686');
        element_not_present('#flavor_NET_arch_x86_64');
    };
};

subtest 'filtering by test' => sub {

    subtest 'request for specific test' => sub {
        $driver->get('/tests/overview?test=textmode');

        my @rows = $driver->find_elements('#content tbody tr');
        is(scalar @rows, 1, 'exactly one row present');
        like($rows[0]->get_text(), qr/textmode/, 'test is textmode');
        like(
            OpenQA::Test::Case::trim_whitespace($driver->find_element('#summary .card-header')->get_text()),
            qr/Overall Summary of opensuse 13\.1 build 0092/,
            'summary states "opensuse 13.1" although no explicit search params',
        );
    };

    $driver->get('/tests/overview?distri=opensuse&version=13.1&build=0091');

    subtest 'by default, all tests present' => sub {
        check_build_0091_defaults;
    };

    subtest 'filter for specific test' => sub {
        $driver->find_element('#filter-panel .card-header')->click();
        $driver->find_element('#filter-test')->send_keys('textmode');
        $driver->find_element('#filter-panel .btn-default')->click();

        my @rows = $driver->find_elements('#content tbody tr');
        is(scalar @rows, 1, 'exactly one row present');
        like($rows[0]->get_text(), qr/textmode/, 'test is textmode');
    };
};

subtest 'empty flavor value does not result in all jobs being loaded (regression test)' => sub {
    $driver->get('/tests/overview?test=textmode&flavor=');
    like(
        OpenQA::Test::Case::trim_whitespace($driver->find_element('#summary .card-header')->get_text()),
        qr/Overall Summary of opensuse 13\.1 build 0092/,
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
            OpenQA::Test::Case::trim_whitespace($driver->find_element('#summary .card-header strong')->get_text()),
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
    is(scalar @{$driver->find_elements('#res-99946')}, 1, 'textmode job still shown');
    is(scalar @{$driver->find_elements('#res-99920')}, 0, 'and old kde job not revealed');

    $driver->get('/tests/overview?arch=&failed_modules=zypper_up&distri=opensuse&version=13.1&build=0091&groupid=1001');
    is($driver->find_element('#summary .badge-danger')->get_text(),
        '1', 'filtering for failed modules works for latest job');
    is(scalar @{$driver->find_elements('#res-99946')}, 1, 'textmode job matches failed modules filter');

    $driver->get('/tests/overview?arch=&failed_modules=bar&distri=opensuse&version=13.1&build=0091&groupid=1001');
    is scalar @{$driver->find_elements('#summary .badge-danger')}, 0,
      'filtering for failed modules does not reveal old job';
};

subtest 'filtering by module' => sub {
    my $module = 'kate';
    my $JOB_ICON_SELECTOR = 'td[id^="res_DVD_"]';
    my $result = 'failed';

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
        my $modules = 'kate,zypper_up';
        my $number_of_found_jobs = 2;
        $driver->get("/tests/overview?arch=&distri=opensuse&modules=$modules&modules_result=$result");
        my @jobs = $driver->find_elements($JOB_ICON_SELECTOR);
        # Assert that all the jobs with the specified modules and result are shown in the results
        is(scalar @jobs, $number_of_found_jobs, "$number_of_found_jobs jobs with \"$modules\" modules found");
        element_visible('#res_DVD_i586_kde');
        element_visible('#res_DVD_i586_textmode');
    };
};

subtest 'filtering by module_re' => sub {
    my $module_re = 'Maintainer.*okurz';
    my $job_icon_selector = 'td[id^="res_DVD_"]';
    my $result = 'failed';

    subtest "jobs containing the module with any result are present" => sub {
        my $number_of_found_jobs = 3;
        $driver->get("/tests/overview?arch=&distri=opensuse&module_re=$module_re");
        my @jobs = $driver->find_elements($job_icon_selector);
        # Assert that all the jobs with the specified module are shown in the results
        is(scalar @jobs, $number_of_found_jobs, "$number_of_found_jobs jobs with \"$module_re\" regexp module found");
        element_visible('#res_DVD_i586_kde');
        element_visible('#res_DVD_x86_64_kde');
        element_visible('#res_DVD_x86_64_doc');
    };

    subtest "jobs containing the module with the specified result are present" => sub {
        my $number_of_found_jobs = 1;
        $driver->get("/tests/overview?arch=&distri=opensuse&module_re=$module_re&modules_result=$result");
        my @jobs = $driver->find_elements($job_icon_selector);
        # Assert that all the jobs with the specified module and result are shown in the results
        is(scalar @jobs, $number_of_found_jobs, "$number_of_found_jobs jobs with \"$module_re\" module regexp found");
        element_visible('#res_DVD_i586_kde');
    };

};

subtest "filtering by machine" => sub {
    $driver->get('/tests/overview?distri=opensuse&version=13.1&build=0091');

    subtest 'by default, all machines for all flavors present' => sub {
        check_build_0091_defaults;
    };

    subtest 'filter for specific machine' => sub {
        $driver->find_element('#filter-panel .card-header')->click();
        $driver->find_element('#filter-machine')->send_keys('uefi');
        $driver->find_element('#filter-panel .btn-default')->click();

        element_visible('#flavor_DVD_arch_x86_64', qr/x86_64/);
        element_not_present('#flavor_DVD_arch_i586');
        element_not_present('#flavor_GNOME-Live_arch_i686');
        element_not_present('#flavor_NET_arch_x86_64');

        my @row = $driver->find_element('#content tbody tr');
        is(scalar @row, 1, 'The job its machine is uefi is shown');

        is($driver->find_element('#content tbody .name span')->get_text(), 'kde@uefi', 'Test suite name is shown');
        $driver->find_element('#filter-panel .card-header')->click();
        is(element_prop('filter-machine'), 'uefi', 'machine text is correct');

        $driver->find_element('#filter-machine')->clear();
        $driver->find_element('#filter-machine')->send_keys('64bit,uefi');
        $driver->find_element('#filter-panel .btn-default')->click();

        element_visible('#flavor_DVD_arch_x86_64', qr/x86_64/);
        element_visible('#flavor_NET_arch_x86_64', qr/x86_64/);
        element_not_present('#flavor_GONME-Live_arch_i686');
        element_not_present('#flavor_DVD_arch_i586');

    };
};

subtest 'filtering by job group' => sub {
    $schema->resultset('JobGroups')->create($_)
      for (
        {
            id => 1003,
            sort_order => 0,
            name => 'opensuse development'
        },
        {
            id => 1004,
            sort_order => 0,
            name => 'Tumbleweed'
        },
        {
            id => 1005,
            sort_order => 0,
            name => 'SLE 15 SP5'
        },
        {
            id => 1006,
            sort_order => 0,
            name => 'SLE 15 SP5 development'
        });

    my $get_text = sub {
        $driver->get(shift);
        my @el = $driver->find_element('.card-header');
        return $el[0]->get_text;
    };

    subtest 'filter with exact include' => sub {
        my $text = $get_text->('/tests/overview?group_glob=opensuse');
        like $text, qr/Summary of opensuse build/, 'job group match';
    };

    subtest 'filter with glob include' => sub {
        my $text = $get_text->('/tests/overview?group_glob=*opensuse*');
        like $text, qr/Summary of opensuse, opensuse test, opensuse development build/, 'job group match';
    };

    subtest 'filter with multiple glob includes' => sub {
        my $text = $get_text->('/tests/overview?group_glob=opensuse*,SLE*');
        like $text,
          qr/Summary of opensuse, opensuse test, opensuse development, SLE 15 SP5, SLE 15 SP5 development build/,
          'job group match';
    };

    subtest 'filter with exact exclude' => sub {
        my $text = $get_text->('/tests/overview?not_group_glob=opensuse');
        like $text,
          qr/Summary of opensuse test, opensuse development, Tumbleweed, SLE 15 SP5, SLE 15 SP5 development build/,
          'job group match';
    };

    subtest 'filter with glob exclude' => sub {
        my $text = $get_text->('/tests/overview?not_group_glob=*SLE*');
        like $text, qr/Summary of opensuse, opensuse test, opensuse development, Tumbleweed build/, 'job group match';
    };

    subtest 'filter with glob include and exclude' => sub {
        my $text = $get_text->('/tests/overview?group_glob=*opensuse*,*SLE*&not_group_glob=*development*');
        like $text, qr/Summary of opensuse, opensuse test, SLE 15 SP5 build/, 'job group match';
    };

    subtest 'filter with glob and no match' => sub {
        my $text = $get_text->('/tests/overview?group_glob=does_not_exist');
        like $text, qr/Overall Summary of multiple distri\/version/, 'no match';
    };
};

subtest "job template names displayed on 'Test result overview' page" => sub {
    $driver->get('/group_overview/1002');
    is($driver->find_element('.progress-bar-failed')->get_text(), '1 failed', 'The number of failed jobs is right');
    is($driver->find_element('.progress-bar-unfinished')->get_text(),
        '1 unfinished', 'The number of unfinished jobs is right');

    $driver->get('/tests/overview?distri=opensuse&version=13.1&build=0091&groupid=1002');
    my @tds = $driver->find_elements('#results_DVD tbody tr .name');
    is($tds[0]->get_text(), 'kde_variant', 'job template name kde_variant displayed correctly');

    my @descriptions = $driver->find_elements('td.name a', 'css');
    is(scalar @descriptions, 2, 'only test suites with description content are shown as links');
    disable_bootstrap_animations;
    $descriptions[0]->click();
    is(wait_for_element(selector => '.popover-header')->get_text, 'kde_variant', 'description popover shows content');
};

subtest "job dependencies displayed on 'Test result overview' page" => sub {
    $jobs->find(99938)->update({VERSION => '13.1', BUILD => '0091'});
    $driver->get($baseurl . 'tests/overview?distri=opensuse&version=13.1&build=0091&groupid=1001');
    my $deps = $driver->find_element('td#res_DVD_x86_64_kde .dependency');
    my @child_elements = $driver->find_child_elements($deps, 'a');
    my $details = $child_elements[0];
    like $details->get_attribute('href'), qr{tests/99963\#dependencies}, 'job href is shown correctly';
    is $details->get_attribute('title'), "1 parallel parent\ndependency passed", 'dependency is shown correctly';

    my $parent_ele = $driver->find_element('td#res_DVD_i586_kde .parents_children');
    $driver->move_to(element => $parent_ele);
    my @child_deps = $driver->find_elements('tr.highlight_child');
    is scalar @child_deps, 1, 'child job was highlighted';
    is $driver->find_child_element($child_deps[0], '#res_DVD_x86_64_doc')->get_attribute('name'), 'jobid_td_99938',
      'child job was highlighted correctly';
    my $child_ele = $driver->find_element('td#res_DVD_x86_64_doc .parents_children');
    $driver->move_to(element => $child_ele);
    my @parent_deps = $driver->find_elements('tr.highlight_parent');
    is scalar @parent_deps, 1, 'parent job was highlighted';
    is $driver->find_child_element($parent_deps[0], '#res_DVD_i586_kde')->get_attribute('name'), 'jobid_td_99937',
      'parent job was highlighted correctly';
};

kill_driver();

done_testing();
