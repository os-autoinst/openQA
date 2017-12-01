#! /usr/bin/perl

# Copyright (C) 2016-2017 SUSE LLC
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
    $ENV{OPENQA_TEST_IPC} = 1;
}

use Mojo::Base -strict;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Date::Format;
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;

OpenQA::Test::Case->new->init_data;

use OpenQA::SeleniumTest;

my $t = Test::Mojo->new('OpenQA::WebAPI');

sub schema_hook {
    my $schema        = OpenQA::Test::Database->new->create;
    my $parent_groups = $schema->resultset('JobGroupParents');
    my $job_groups    = $schema->resultset('JobGroups');
    my $jobs          = $schema->resultset('Jobs');
    # add job groups from fixtures to new parent
    my $parent_group = $parent_groups->create({name => 'Test parent', sort_order => 0});
    while (my $job_group = $job_groups->next) {
        $job_group->update(
            {
                parent_id => $parent_group->id
            });
    }
    # add data to test same name job group within different parent group
    my $parent_group2 = $parent_groups->create({name => 'Test parent 2', sort_order => 1});
    my $new_job_group = $job_groups->create({name => 'opensuse', parent_id => $parent_group2->id});
    my $new_job = $jobs->create(
        {
            id         => 100001,
            group_id   => $new_job_group->id,
            result     => "none",
            state      => "cancelled",
            priority   => 35,
            t_finished => undef,
            backend    => 'qemu',
            # 10 minutes ago
            t_started => time2str('%Y-%m-%d %H:%M:%S', time - 600, 'UTC'),
            # Two hours ago
            t_created  => time2str('%Y-%m-%d %H:%M:%S', time - 7200, 'UTC'),
            TEST       => "upgrade",
            ARCH       => 'x86_64',
            BUILD      => '0100',
            DISTRI     => 'opensuse',
            FLAVOR     => 'NET',
            MACHINE    => '64bit',
            VERSION    => '13.1',
            result_dir => '00099961-opensuse-13.1-DVD-x86_64-Build0100-kde',
            settings   => [
                {key => 'DESKTOP',     value => 'kde'},
                {key => 'ISO_MAXSIZE', value => '4700372992'},
                {key => 'ISO',         value => 'openSUSE-13.1-DVD-x86_64-Build0100-Media.iso'},
                {key => 'DVD',         value => '1'},
            ]});
}

my $driver = call_driver(\&schema_hook);
unless ($driver) {
    plan skip_all => $OpenQA::SeleniumTest::drivermissing;
    exit(0);
}

# don't tests basics here again, this is already done in t/22-dashboard.t and t/ui/14-dashboard.t

sub disable_bootstrap_animations {
    $driver->execute_script(
"document.styleSheets[0].addRule('.collapsing', '-webkit-transition: none !important; transition: none !important;', 1);"
    );
}

$driver->title_is('openQA', 'on main page');
my $baseurl = $driver->get_current_url();

$driver->get($baseurl . '?limit_builds=20');
disable_bootstrap_animations();

# test expanding/collapsing
is(scalar @{$driver->find_elements('opensuse', 'link_text')}, 0, 'link to child group collapsed (in the first place)');
$driver->find_element_by_link_text('Build0091')->click();
my $element = $driver->find_element_by_link_text('opensuse');
ok($element->is_displayed(), 'link to child group expanded');

# first try of click does not work for unknown reasons
for (0 .. 10) {
    $driver->find_element_by_link_text('Build0091')->click();
    last if $driver->find_element('#group1_build13_1-0091 .h4 a')->is_hidden();
}
ok($driver->find_element('#group1_build13_1-0091 .h4 a')->is_hidden(), 'link to child group collapsed');

# go to parent group overview
$driver->find_element_by_link_text('Test parent')->click();
disable_bootstrap_animations();

ok($driver->find_element('#group1_build13_1-0091 .h4 a')->is_displayed(), 'link to child group displayed');
my @links = $driver->find_elements('.h4 a', 'css');
is(scalar @links, 11, 'all links expanded in the first place');
$driver->find_element_by_link_text('Build0091')->click();
ok($driver->find_element('#group1_build13_1-0091 .h4 a')->is_hidden(), 'link to child group collapsed');

# check same name group within different parent group
isnt(scalar @{$driver->find_elements('opensuse', 'link_text')}, 0, "child group 'opensuse' in 'Test parent'");

# back to home and go to another parent group overview
$driver->find_element_by_class('navbar-brand')->click();
$driver->find_element_by_link_text('Test parent 2')->click();
disable_bootstrap_animations();
isnt(scalar @{$driver->find_elements('opensuse', 'link_text')}, 0, "child group 'opensuse' in 'Test parent 2'");

kill_driver();
done_testing();
