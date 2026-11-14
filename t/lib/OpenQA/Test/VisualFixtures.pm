# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Test::VisualFixtures;
use Mojo::Base -strict, -signatures;

use Exporter 'import';
use OpenQA::Test::Case;
use OpenQA::SeleniumTest;

our @EXPORT_OK = qw(init_visual_data visual_pages login);

my @pages = (
    ['front_page', '/'],
    ['tests_overview', '/tests?limit=20'],
    ['test_details', '/tests/99938'],
    ['group_overview', '/group_overview/1001'],
    ['admin_groups', '/admin/groups'],
    ['admin_users', '/admin/users'],
);

sub visual_pages () { return @pages }

sub login ($driver, $url) {
    $driver->get($url . '/');
    $driver->find_element_by_link_text('Login')->click;
    wait_for_ajax_and_animations;
}

sub init_visual_data ($fixed_time = undef) {
    my $schema = OpenQA::Test::Case->new->init_data(
        schema_name => $ENV{OPENQA_TEST_SCHEMA},
        fixtures_glob => '01-jobs.pl 02-workers.pl 03-users.pl 04-products.pl 05-job_modules.pl 06-job_dependencies.pl'
    );
    for my $text ('label:staging bsc#1234', 'flag:iso bsc#111111') {
        my $comment = $schema->resultset('Comments')->create({text => $text, user_id => 1, job_id => 99938});
        $comment->update({t_created => $fixed_time}) if $fixed_time;
    }
    return $schema;
}

1;
