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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

BEGIN {
    unshift @INC, 'lib';
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

my $t = Test::Mojo->new('OpenQA::WebAPI');

sub get_summary {
    return OpenQA::Test::Case::trim_whitespace($t->tx->res->dom->at('#summary')->all_text);
}

#
# Overview with incorrect parameters
#
$t->get_ok('/tests/overview')->status_is(404);
$t->get_ok('/tests/overview' => form => {build => '0091'})->status_is(404);
$t->get_ok('/tests/overview' => form => {build => '0091', distri => 'opensuse'})->status_is(404);
$t->get_ok('/tests/overview' => form => {build => '0091', version => '13.1'})->status_is(404);

#
# Overview of build 0091
#
my $get = $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => '13.1', build => '0091'});
$get->status_is(200);

my $summary = get_summary;
like($summary, qr/Overall Summary of opensuse 13\.1 build 0091/i);
like($summary, qr/Passed: 2 Failed: 0 Scheduled: 2 Running: 2 None: 1/i);

# Check the headers
$get->element_exists('#flavor_DVD_arch_i586');
$get->element_exists('#flavor_DVD_arch_x86_64');
$get->element_exists('#flavor_GNOME-Live_arch_i686');
$get->element_exists_not('#flavor_GNOME-Live_arch_x86_64');
$get->element_exists_not('#flavor_DVD_arch_i686');

# Check some results (and it's overview_xxx classes)
$get->element_exists('#res_DVD_i586_kde .result_passed');
$get->element_exists('#res_GNOME-Live_i686_RAID0 i.state_cancelled');
$get->element_exists('#res_DVD_i586_RAID1 i.state_scheduled');
$get->element_exists_not('#res_DVD_x86_64_doc');

my $form = {distri => 'opensuse', version => '13.1', build => '0091', group => 'opensuse 13.1'};
$get = $t->get_ok('/tests/overview' => form => $form)->status_is(200);
like(get_summary, qr/Overall Summary of opensuse 13\.1 build 0091/i, 'specifying group parameter');
$form = {distri => 'opensuse', version => '13.1', build => '0091', groupid => 1001};
$get = $t->get_ok('/tests/overview' => form => $form)->status_is(200);
like(get_summary, qr/Overall Summary of opensuse build 0091/i, 'specifying groupid parameter');

#
# Overview of build 0048
#
$get = $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => 'Factory', build => '0048'});
$get->status_is(200);
like(get_summary, qr/\QPassed: 0 Soft Failure: 2 Failed: 1\E/i);

# Check the headers
$get->element_exists('#flavor_DVD_arch_x86_64');
$get->element_exists_not('#flavor_DVD_arch_i586');
$get->element_exists_not('#flavor_GNOME-Live_arch_i686');

# Check some results (and it's overview_xxx classes)
$get->element_exists('#res_DVD_x86_64_doc .result_failed');
$get->element_exists('#res_DVD_x86_64_kde .result_softfailed');
$get->element_exists_not('#res_DVD_i586_doc');
$get->element_exists_not('#res_DVD_i686_doc');

my $failedmodules
  = OpenQA::Test::Case::trim_whitespace($t->tx->res->dom->at('#res_DVD_x86_64_doc .failedmodule a')->all_text);
like($failedmodules, qr/logpackages/i, "failed modules are listed");

#
# Default overview for 13.1
#
$get = $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => '13.1'});
$get->status_is(200);
$summary = get_summary;
like($summary, qr/Summary of opensuse 13\.1 build 0091/i);
like($summary, qr/Passed: 2 Failed: 0 Scheduled: 2 Running: 2 None: 1/i);

$form = {distri => 'opensuse', version => '13.1', groupid => 1001};
$get = $t->get_ok('/tests/overview' => form => $form)->status_is(200);
like(
    get_summary,
    qr/Summary of opensuse build 0091/i,
    'specifying job group but with no build yields latest build in this group'
);

#
# Default overview for Factory
#
$get = $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => 'Factory'});
$get->status_is(200);
$summary = get_summary;
like($summary, qr/Summary of opensuse Factory build 0048\@0815/i);
like($summary, qr/\QPassed: 0 Failed: 1\E/i);


#
# Still possible to check an old build
#
$get = $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => 'Factory', build => '87.5011'});
$get->status_is(200);
$summary = get_summary;
like($summary, qr/Summary of opensuse Factory build 87.5011/);
like($summary, qr/Passed: 0 Incomplete: 1 Failed: 0/);

# Advanced query parameters can be forwarded
$form = {distri => 'opensuse', version => '13.1', result => 'passed'};
$get = $t->get_ok('/tests/overview' => form => $form)->status_is(200);
$summary = get_summary;
like($summary, qr/Summary of opensuse 13\.1 build 0091/i, "Still references the last build");
like($summary, qr/Passed: 2 Failed: 0/i, "Only passed are shown");
$get->element_exists('#res_DVD_i586_kde .result_passed');
$get->element_exists('#res_DVD_i586_textmode .result_passed');
$get->element_exists_not('#res_DVD_i586_RAID0 .state_scheduled');
$get->element_exists_not('#res_DVD_x86_64_kde .state_running');
$get->element_exists_not('#res_GNOME-Live_i686_RAID0 .state_cancelled');
$get->element_exists_not('.result_failed');
$get->element_exists_not('.state_cancelled');

# This time show only failed
$form = {distri => 'opensuse', version => 'Factory', build => '0048', result => 'failed'};
$get = $t->get_ok('/tests/overview' => form => $form)->status_is(200);
like(get_summary, qr/Passed: 0 Failed: 1/i);
$get->element_exists('#res_DVD_x86_64_doc .result_failed');
$get->element_exists_not('#res_DVD_x86_64_kde .result_passed');

$form = {distri => 'opensuse', version => 'Factory', build => '0048', todo => 1};
$get = $t->get_ok('/tests/overview' => form => $form)->status_is(200);
like(
    get_summary,
    qr/Passed: 0 Failed: 1/i,
    'todo=1 shows only unlabeled left failed as softfailed with failing modules was labeled'
);

# add a failing module to one of the softfails to test 'TODO' option
my $failing_module = $t->app->db->resultset('JobModules')->create(
    {
        script   => 'tests/x11/failing_module.pm',
        job_id   => 99936,
        category => 'x11',
        name     => 'failing_module',
        result   => 'failed'
    });

$get = $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => 'Factory', build => '0048', todo => 1})
  ->status_is(200);
like(
    get_summary,
    qr/Passed: 0 Soft Failure: 1 Failed: 1/i,
    'todo=1 shows only unlabeled left failed as softfailed with failing modules was labeled'
);
$t->element_exists_not('#res-99939', 'softfailed without failing module filtered out');
$t->element_exists('#res-99936', 'softfailed with unreviewed failing module present');

my $review_comment = $t->app->db->resultset('Comments')->create(
    {
        job_id  => 99936,
        text    => 'bsc#1234',
        user_id => 99903,
    });
$get = $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => 'Factory', build => '0048', todo => 1})
  ->status_is(200);
like(
    get_summary,
    qr/Passed: 0 Failed: 1/i,
    'todo=1 shows only unlabeled left failed as softfailed with failing modules was labeled'
);
$t->element_exists_not('#res-99936', 'softfailed with reviewed failing module filtered out');

$review_comment->delete();
$failing_module->delete();

# multiple groups can be shown at the same time
$get = $t->get_ok('/tests/overview?distri=opensuse&version=13.1&groupid=1001&groupid=1002&build=0091')->status_is(200);
$summary = get_summary;
like($summary, qr/Summary of opensuse, opensuse test/i, 'references both groups selected by query');
like($summary, qr/Passed: 2 Failed: 0 Scheduled: 1 Running: 2 None: 1/i,
    'shows latest jobs from both groups 1001/1002');
$get->element_exists('#res_DVD_i586_kde',                           'job from group 1001 is shown');
$get->element_exists('#res_GNOME-Live_i686_RAID0 .state_cancelled', 'another job from group 1001');
$get->element_exists('#res_NET_x86_64_kde .state_running',          'job from group 1002 is shown');

$get     = $t->get_ok('/tests/overview?distri=opensuse&version=13.1&groupid=1001&groupid=1002')->status_is(200);
$summary = get_summary;
like(
    $summary,
    qr/Summary of opensuse, opensuse test/i,
    'multiple groups with no build specified yield latest build of first group'
);
like($summary, qr/Passed: 2 Failed: 0 Scheduled: 1 Running: 2 None: 1/i);

#
# Test filter form
#

# Test initial state of architecture text box
$form = {distri => 'opensuse', version => 'Factory', result => 'passed', arch => 'i686'};
$get = $t->get_ok('/tests/overview' => form => $form)->status_is(200);
# FIXME: works when testing manually, but accessing the value via Mojo doesn't work
#is($t->tx->res->dom->at('#filter-arch')->val, 'i686', 'default state of architecture');

# more UI tests of the filter form are in t/ui/10-tests_overview.t based on phantomjs

$t->get_ok('/tests/99937/modules/kate/fails')->json_is('/failed_needles' => ["test-kate-1"], 'correct failed needles');
$t->get_ok('/tests/99937/modules/zypper_up/fails')
  ->json_is('/first_failed_step' => 1, 'failed module: fallback to first step');

done_testing();
