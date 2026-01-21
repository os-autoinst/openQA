# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '8';
use OpenQA::Test::Case;

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 03-users.pl');

subtest 'delete buttons not visible for not-logged-in/non-admin' => sub {
    my $t = Test::Mojo->new('OpenQA::WebAPI');
    $t->get_ok('/admin/groups')->status_is(200);
    $t->element_exists_not('a[title^="Delete job group"]', 'Delete job group button not visible');
    $t->element_exists_not('a[title^="Delete parent group"]', 'Delete parent group button not visible');
};

subtest 'delete buttons visible for admin' => sub {
    my $t = Test::Mojo->new('OpenQA::WebAPI');
    $t->post_ok('/login', form => {user => 'Demo'})->status_is(302);
    my $parent = $t->app->schema->resultset('JobGroupParents')->create({name => 'Test Parent Group'});
    $t->get_ok('/admin/groups')->status_is(200);
    $t->element_exists('a[title^="Delete job group"]', 'Delete job group button visible');
    $t->element_exists('a[title^="Delete parent group"]', 'Delete parent group button visible');
    $t->element_exists('a[title="Delete parent group Test Parent Group"]',
        'Delete button for specific parent group visible');
};

done_testing();
