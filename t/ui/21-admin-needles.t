#!/usr/bin/env perl
# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Date::Format 'time2str';
use Test::Warnings qw(:all :report_warnings);
use OpenQA::Test::TimeLimit '20';
use OpenQA::Test::Case;
use Time::HiRes qw(sleep);
use OpenQA::SeleniumTest;
use Mojo::File 'path';
use Mojo::JSON 'decode_json';
use Cwd qw(getcwd);
use DateTime;

my $test_case = OpenQA::Test::Case->new;
my $schema_name = OpenQA::Test::Database->generate_schema_name;
my $schema
  = $test_case->init_data(schema_name => $schema_name, fixtures_glob => '01-jobs.pl 05-job_modules.pl 07-needles.pl');

# ensure needle dir can be listed (might not be the case because previous test run failed)
my $needle_dir = 't/data/openqa/share/tests/opensuse/needles/';
chmod(0755, $needle_dir);

$schema->resultset('Needles')->create(
    {
        dir_id => 1,
        filename => 'never-matched.json',
        last_seen_module_id => 10,
        last_seen_time => time2str('%Y-%m-%d %H:%M:%S', time - 100000),
        last_matched_module_id => undef,
        file_present => 1,
    });

driver_missing unless my $driver = call_driver();

# We need a fake Minion worker because not having an active worker results in error messages from the UI
my $fake_app = Mojo::Server->new->build_app('OpenQA::WebAPI');
my $minion = $fake_app->minion;
my $fake_worker = $minion->worker->register;

my @needle_files = qw(inst-timezone-text.json inst-timezone-text.png never-matched.json never-matched.png);
# create dummy files for needles
path($needle_dir)->make_path;
map { path($needle_dir, $_)->spurt('go away later') } @needle_files;

$driver->title_is("openQA", "on main page");
$driver->find_element_by_link_text('Login')->click();
# we're back on the main page
$driver->title_is("openQA", "back on main page");

sub goto_admin_needle_table {
    my $login_link = $driver->find_element('#user-action > a');
    is($login_link->get_text(), 'Logged in as Demo', 'logged in as demo');
    # the following should work, but apparently doesn't - at least when executing tests in CI:
    #   $login_link->click();
    #   $driver->find_element_by_link_text('Needles')->click();
    # see https://github.com/os-autoinst/openQA/pull/1619#issuecomment-381554863
    # so navigate to admin needles page by using the URL directly
    $driver->get('/admin/needles');
    wait_for_ajax(with_minion => $minion);
}
goto_admin_needle_table();

my @trs = $driver->find_elements('#needles tr', 'css');
# skip header
my @tds = $driver->find_child_elements($trs[1], 'td', 'css');
is((shift @tds)->get_text(), 'fixtures', "Path is fixtures");
is((shift @tds)->get_text(), 'inst-timezone-text.json', "Name is right");
is((my $module_link = shift @tds)->get_text(), 'a day ago', "last use is right");
is((shift @tds)->get_text(), 'about 14 hours ago', "last match is right");
@tds = $driver->find_child_elements($trs[2], 'td', 'css');
is((shift @tds)->get_text(), 'fixtures', "Path is fixtures");
is((shift @tds)->get_text(), 'never-matched.json', "Name is right");
is((shift @tds)->get_text(), 'a day ago', "last use is right");
is((shift @tds)->get_text(), 'never', "last match is right");
$driver->find_child_element($module_link, 'a', 'css')->click();
like(
    $driver->execute_script("return window.location.href"),
    qr(\Q/tests/99937#step/partitioning_finish/1\E),
    "redirected to right module"
);

goto_admin_needle_table();

$driver->find_element_by_link_text('about 14 hours ago')->click();
like(
    $driver->execute_script("return window.location.href"),
    qr(\Q/tests/99937#step/partitioning/1\E),
    "redirected to right module too"
);

subtest 'dereference symlink when displaying needles info' => sub {
    my $real_needle_dir = getcwd . '/t/data/openqa/share/tests/opensuse';
    my $symlink_needle_dir = getcwd . '/t/data/openqa/share/tests/test_symlink_dir';
    unlink($symlink_needle_dir);
    symlink($real_needle_dir, $symlink_needle_dir) or die "Cannot make symlink $!";
    my $needle_dir = $schema->resultset('NeedleDirs');
    my $symlink_needle_dir_id = $needle_dir->create(
        {
            path => $symlink_needle_dir . '/needles',
            name => '1symlink_needle_dir'
        })->id;
    my $real_needle_dir_id = $needle_dir->create(
        {
            path => $real_needle_dir . '/needles',
            name => 'real_needle_dir'
        })->id;
    my $needles = $schema->resultset('Needles');
    my @need_deleted_needles;
    my $symlink_needle = $needles->create(
        {
            dir_id => $symlink_needle_dir_id,
            filename => 'bootloader.json',
            last_seen_module_id => undef,
            last_seen_time => undef,
            last_matched_time => undef,
            last_matched_module_id => undef,
            file_present => 1,
        });
    push @need_deleted_needles, $symlink_needle;

    my $default_show_needles_num = 10;
    for (my $i = 1; $i < $default_show_needles_num; $i++) {
        my $added_needle = $needles->create(
            {
                dir_id => $symlink_needle_dir_id,
                filename => $i . '.json',
                last_seen_module_id => undef,
                last_seen_time => undef,
                last_matched_time => undef,
                last_matched_module_id => undef,
                file_present => 1,
            });
        push @need_deleted_needles, $added_needle;
    }
    my $real_needle = $needles->create(
        {
            dir_id => $real_needle_dir_id,
            filename => 'bootloader.json',
            last_seen_module_id => 10,
            last_seen_time => time2str('%Y-%m-%d %H:%M:%S', time - 100000),
            last_matched_module_id => 9,
            last_matched_time => time2str('%Y-%m-%d %H:%M:%S', time - 50000),
            file_present => 1,
            t_created => time2str('%Y-%m-%d %H:%M:%S', time - 200000),
            t_updated => time2str('%Y-%m-%d %H:%M:%S', time - 200000),
        });
    push @need_deleted_needles, $real_needle;

    my $real_needle_id = $real_needle->id;
    my $last_seen_module_id = $real_needle->last_seen_module_id;
    my $last_matched_module_id = $real_needle->last_matched_module_id;

    goto_admin_needle_table();
    my @needle_trs = $driver->find_elements('#needles tbody tr');
    is(scalar(@needle_trs), 10, '10 added needles shown');
    my @symlink_needle_tds = $driver->find_child_elements($needle_trs[9], 'td', 'css');
    is((shift @symlink_needle_tds)->get_text(), '1symlink_needle_dir', 'symlink needle dir is displayed correctly');
    is((shift @symlink_needle_tds)->get_text(), 'bootloader.json', 'symlink needle file name is displayed correctly');
    my $last_used_td = shift @symlink_needle_tds;
    is($last_used_td->get_text(), 'a day ago', 'symlink needle last use is displayed correctly');
    like(
        $driver->find_child_element($last_used_td, 'a')->get_attribute('href'),
        qr/admin\/needles\/$last_seen_module_id\/$real_needle_id/,
        'symlink needle last used module link is correctly'
    );
    my $last_matched_td = shift @symlink_needle_tds;
    is($last_matched_td->get_text(), 'about 14 hours ago', 'symlink needle last match is displayed correctly');
    like(
        $driver->find_child_element($last_matched_td, 'a')->get_attribute('href'),
        qr/admin\/needles\/$last_matched_module_id\/$real_needle_id/,
        'symlink needle last used module link is correct'
    );

    $_->delete for @need_deleted_needles;
    unlink($symlink_needle_dir);
};
goto_admin_needle_table();

subtest 'delete needle' => sub {
    # disable animations to speed up test
    $driver->execute_script('$(\'#confirm_delete\').removeClass(\'fade\');');

    # select first needle and open modal dialog for deletion
    $driver->find_element('td input')->click();
    wait_for_ajax(with_minion => $minion);
    $driver->find_element_by_id('delete_all')->click();

    is($driver->find_element_by_id('confirm_delete')->is_displayed(), 1, 'modal dialog');
    is($driver->find_element('#confirm_delete .modal-title')->get_text(), 'Needle deletion', 'title matches');
    is(scalar @{$driver->find_elements('#outstanding-needles li', 'css')}, 1, 'one needle outstanding for deletion');
    is(scalar @{$driver->find_elements('#failed-needles li', 'css')}, 0, 'no failed needles so far');
    is($driver->find_element('#outstanding-needles li')->get_text(),
        'inst-timezone-text.json', 'right needle name displayed');

    subtest 'error case' => sub {
        chmod(0444, $needle_dir);
        $driver->find_element_by_id('really_delete')->click();
        wait_for_ajax(with_minion => $minion);
        is(scalar @{$driver->find_elements('#outstanding-needles li', 'css')}, 0, 'no outstanding needles');
        is(scalar @{$driver->find_elements('#failed-needles li', 'css')}, 1, 'but failed needle');
        is(
            $driver->find_element('#failed-needles li')->get_text(),
"inst-timezone-text.json\nUnable to delete t/data/openqa/share/tests/opensuse/needles/inst-timezone-text.json and t/data/openqa/share/tests/opensuse/needles/inst-timezone-text.png",
            'right needle name and error message displayed'
        );
        $driver->find_element_by_id('close_delete')->click();
    };

    # select all needles and re-open modal dialog for deletion
    wait_for_ajax(with_minion => $minion);    # required due to server-side datatable
    $_->click() for $driver->find_elements('td input', 'css');
    $driver->find_element_by_id('delete_all')->click();
    my @outstanding_needles = $driver->find_elements('#outstanding-needles li', 'css');
    is(scalar @outstanding_needles, 2, 'still two needle outstanding for deletion');
    is((shift @outstanding_needles)->get_text(), 'inst-timezone-text.json', 'right needle names displayed');
    is((shift @outstanding_needles)->get_text(), 'never-matched.json', 'right needle names displayed');
    is(scalar @{$driver->find_elements('#failed-needles li', 'css')},
        0, 'failed needles from last time shouldn\'t appear again when reopening deletion dialog');

    subtest 'successful deletion' => sub {
        chmod(0755, $needle_dir);
        $driver->find_element_by_id('really_delete')->click();
        wait_for_ajax(with_minion => $minion);
        is(scalar @{$driver->find_elements('#outstanding-needles li', 'css')}, 0, 'no outstanding needles');
        is(scalar @{$driver->find_elements('#failed-needles li', 'css')}, 0, 'no failed needles');
        $driver->find_element_by_id('close_delete')->click();
        wait_for_ajax(with_minion => $minion);    # required due to server-side datatable
        for my $file_name (@needle_files) {
            is(-f $needle_dir . $file_name, undef, $file_name . ' is gone');
        }
        is($driver->find_element('#needles tbody tr')->get_text(), 'No data available in table', 'no needles left');
    };
};

subtest 'pass invalid IDs to needle deletion route' => sub {
    my $func = 'function(error) { window.deleteMsg = JSON.stringify(error); }';
    ok(
        !$driver->execute_script(
            "jQuery.ajax({url: '/admin/needles/delete?id=42&id=foo', type: 'DELETE', success: $func});"),
        'delete needle with ID 42'
    );
    wait_for_ajax(with_minion => $minion);
    my $error = decode_json($driver->execute_script('return window.deleteMsg;'));
    is_deeply(
        $error,
        {
            errors => [
                {id => 42, message => 'Unable to find needle with ID "42"'},
                {id => 'foo', message => 'Unable to find needle with ID "foo"'},
            ],
            removed_ids => []
        },
        'error returned'
    );
};

subtest 'custom needles search' => sub {
    my $needles = $schema->resultset('Needles');
    my $five_months_ago = DateTime->now()->subtract(months => 5)->strftime('%Y-%m-%d %H:%M:%S');
    my $seven_months_ago = DateTime->now()->subtract(months => 7)->strftime('%Y-%m-%d %H:%M:%S');
    my %created_needles = (
        five_month => $five_months_ago,
        seven_month => $seven_months_ago,
    );
    for my $t (keys %created_needles) {
        my $needle_name = "$t.json";
        $needles->create(
            {
                dir_id => 1,
                filename => $needle_name,
                last_seen_module_id => 10,
                last_seen_time => $created_needles{$t},
                last_matched_module_id => 9,
                last_matched_time => $created_needles{$t},
                file_present => 1,
                t_created => undef,
                t_updated => undef,
            });
        my $u_needle_name = "$t-undef.json";
        $needles->create(
            {
                dir_id => 1,
                filename => $u_needle_name,
                last_seen_module_id => 10,
                last_seen_time => $created_needles{$t},
                last_matched_module_id => 9,
                last_matched_time => undef,
                file_present => 1,
                t_created => undef,
                t_updated => undef,
            });
    }

    goto_admin_needle_table();
    my @needle_trs = $driver->find_elements('#needles tbody tr');
    is(scalar(@needle_trs), 4, '4 added needles shown');
    is($driver->find_element_by_id('custom_last_seen')->is_displayed(), 0, 'do not show last seen custom area');
    is($driver->find_element_by_id('custom_last_match')->is_displayed(), 0, 'do not show last match custom area');

    my @last_seen_options = $driver->find_elements('#last_seen_filter option');
    my @last_match_options = $driver->find_elements('#last_match_filter option');

    $last_seen_options[7]->click();
    is($driver->find_element_by_id('custom_last_seen')->is_displayed(), 1, 'show last seen custom area');
    $driver->find_element_by_id('btn_custom_last_seen')->click();
    wait_for_ajax(msg => 'custom needle seen "last" range (default 6 months ago)', with_minion => $minion);

    @needle_trs = $driver->find_elements('#needles tbody tr');
    is(scalar(@needle_trs), 2, 'only show five_month and five_month-undef needles');
    my @needle_tds = $driver->find_child_elements($needle_trs[0], 'td', 'css');
    is($needle_tds[1]->get_text(), 'five_month.json', 'search five_month needle correctly');
    @needle_tds = $driver->find_child_elements($needle_trs[1], 'td', 'css');
    is($needle_tds[1]->get_text(), 'five_month-undef.json', 'search five_month-undef needle correctly');

    $last_match_options[7]->click();
    is($driver->find_element_by_id('custom_last_match')->is_displayed(), 1, 'show last match custom area');
    $driver->find_element_by_id('btn_custom_last_match')->click();
    wait_for_ajax(
        msg => 'custom needle seen "last" and match "last" range (default 6 months ago)',
        with_minion => $minion
    );
    @needle_trs = $driver->find_elements('#needles tbody tr');
    is(scalar(@needle_trs), 1, 'only show five_month needle');
    @needle_tds = $driver->find_child_elements($needle_trs[0], 'td', 'css');
    is($needle_tds[1]->get_text(), 'five_month.json', 'search needle correctly');

    my @sel_custom_last_seen = $driver->find_elements('#sel_custom_last_seen option');
    my @sel_custom_last_match = $driver->find_elements('#sel_custom_last_match option');
    $sel_custom_last_seen[1]->click();
    $driver->find_element_by_id('btn_custom_last_seen')->click();
    wait_for_ajax(msg => 'custom needle seen "not last" and match "last" range', with_minion => $minion);
    @needle_trs = $driver->find_elements('#needles tbody tr');
    @needle_tds = $driver->find_child_elements($needle_trs[0], 'td', 'css');
    is($needle_tds[0]->get_text(), 'No matching records found', 'There is no match needle');

    $sel_custom_last_match[1]->click();
    $driver->find_element_by_id('btn_custom_last_match')->click();
    wait_for_ajax(msg => 'custom needle seen "not last" and match "not last" range', with_minion => $minion);
    @needle_trs = $driver->find_elements('#needles tbody tr');
    is(scalar(@needle_trs), 2, 'show seven_month and seven_month-undef');
    @needle_tds = $driver->find_child_elements($needle_trs[0], 'td', 'css');
    is($needle_tds[1]->get_text(), 'seven_month.json', 'search seven_month needle correctly');
    @needle_tds = $driver->find_child_elements($needle_trs[1], 'td', 'css');
    is($needle_tds[1]->get_text(), 'seven_month-undef.json', 'search seven_month-undef needle correctly');

    $last_seen_options[0]->click();
    $last_match_options[6]->click();
    wait_for_ajax(msg => '"all time" seen and "not last two months" match', with_minion => $minion);
    @needle_trs = $driver->find_elements('#needles tbody tr');
    is(scalar(@needle_trs), 4, 'show all needles');
    @needle_tds = $driver->find_child_elements($needle_trs[0], 'td', 'css');
    is($needle_tds[1]->get_text(), 'five_month.json', 'search five_month needle correctly');
    @needle_tds = $driver->find_child_elements($needle_trs[1], 'td', 'css');
    is($needle_tds[1]->get_text(), 'five_month-undef.json', 'search five_month-undef needle correctly');
    @needle_tds = $driver->find_child_elements($needle_trs[2], 'td', 'css');
    is($needle_tds[1]->get_text(), 'seven_month.json', 'search seven_month needle correctly');
    @needle_tds = $driver->find_child_elements($needle_trs[3], 'td', 'css');
    is($needle_tds[1]->get_text(), 'seven_month-undef.json', 'search seven_month-undef needle correctly');
};

$fake_worker->unregister;

kill_driver();
done_testing();
