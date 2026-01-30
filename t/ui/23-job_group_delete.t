# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '8';
use OpenQA::Test::Case;

use OpenQA::Test::Client;

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 03-users.pl');

my $t = Test::Mojo->new('OpenQA::WebAPI');
my $schema = $t->app->schema;
my $job_groups = $schema->resultset('JobGroups');
my $parent_groups = $schema->resultset('JobGroupParents');

subtest 'delete buttons not visible for not-logged-in/non-admin' => sub {
    $t->get_ok('/admin/groups')->status_is(200);
    $t->element_exists_not('a[title^="Delete job group"]', 'Delete job group button not visible');
    $t->element_exists_not('a[title^="Delete parent group"]', 'Delete parent group button not visible');
};

subtest 'delete buttons visible for admin' => sub {
    $t->post_ok('/login', form => {user => 'Demo'})->status_is(302);
    my $parent = $parent_groups->create({name => 'Test Parent Group'});
    $t->get_ok('/admin/groups')->status_is(200);
    $t->element_exists('a[title^="Delete job group"]', 'Delete job group button visible');
    $t->element_exists('a[title^="Delete parent group"]', 'Delete parent group button visible');
    $t->element_exists('a[title="Delete parent group Test Parent Group"]',
        'Delete button for specific parent group visible');
};

subtest 'destructive delete operation' => sub {
    $t = client($t, apikey => 'ARTHURKEY01', apisecret => 'EXCALIBUR');
    my $parent1 = $parent_groups->create({name => 'Parent 1'});
    my $parent2 = $parent_groups->create({name => 'Parent 2'});
    my $group1 = $job_groups->create({name => 'Group 1', parent_id => $parent1->id});
    my $group2 = $job_groups->create({name => 'Group 2', parent_id => $parent1->id});
    $t->delete_ok('/api/v1/job_groups/' . $group1->id)->status_is(200);
    ok !$job_groups->find($group1->id), 'Group 1 deleted';
    ok $job_groups->find($group2->id), 'Group 2 still exists';
    ok $parent_groups->find($parent1->id), 'Parent 1 still exists';
    $t->delete_ok('/api/v1/parent_groups/' . $parent2->id)->status_is(200);
    ok !$parent_groups->find($parent2->id), 'Parent 2 deleted';
    ok $parent_groups->find($parent1->id), 'Parent 1 still exists after deletion of parent 2';
    $t->delete_ok('/api/v1/parent_groups/' . $parent1->id)->status_is(409);
    ok $parent_groups->find($parent1->id), 'Parent 1 still exists after failed deletion';

    # Test deleting group with jobs
    my $job = $schema->resultset('Jobs')->create(
        {
            group_id => $group2->id,
            priority => 50,
            state => 'done',
            result => 'passed',
            TEST => 'test_job',
            DISTRI => 'distri',
            VERSION => 'version',
            FLAVOR => 'flavor',
            ARCH => 'arch',
            BUILD => 'build'
        });
    $t->delete_ok('/api/v1/job_groups/' . $group2->id)->status_is(409);
    ok $job_groups->find($group2->id), 'Group 2 still exists after failed deletion because of jobs';
};

done_testing();
