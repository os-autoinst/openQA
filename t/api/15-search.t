#!/usr/bin/env perl
# Copyright 2017-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Mojo;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '8';
use OpenQA::Test::Case;

OpenQA::Test::Case->new->init_data;
my $t = Test::Mojo->new('OpenQA::WebAPI');
$t->app->config->{rate_limits}->{search} = 10;

subtest 'Perl modules' => sub {
    $t->get_ok('/api/v1/experimental/search?q=timezone', 'search successful');
    $t->json_is('/error' => undef, 'no errors');
    $t->json_is('/data/0' => {occurrence => 'opensuse/tests/installation/installer_timezone.pm'}, 'module found');
    $t->json_is(
        '/data/1' => {
            occurrence => 'opensuse/tests/installation/installer_timezone.pm',
            contents => qq{    3 # Summary: Verify timezone settings page\n}
              . qq{   11     assert_screen "inst-timezone", 125 || die 'no timezone';}
        },
        'contents found'
    );
};

subtest 'Python modules' => sub {
    $t->get_ok('/api/v1/experimental/search?q=search', 'search successful');
    $t->json_is('/error' => undef, 'no errors');
    $t->json_is('/data/0' => {occurrence => 'opensuse/tests/openQA/search.py'}, 'module found');
    $t->json_is(
        '/data/1' => {
            occurrence => 'opensuse/tests/openQA/search.py',
            contents => qq{    6     assert_and_click('openqa-search')\n}
              . qq{    9     assert_screen('openqa-search-results')}
        },
        'contents found'
    );
};
subtest 'Job modules' => sub {
    my $schema = $t->app->schema;
    my $job = $schema->resultset('Jobs')->create(
        {
            TEST => 'lorem',
        });
    $schema->resultset('JobModules')->create(
        {
            job_id => $job->id,
            script => 'tests/lorem/ipsum.pm',
            category => 'lorem',
            name => 'ipsum',
        });
    $schema->resultset('JobModules')->create(
        {
            job_id => $job->id,
            script => 'tests/lorem/ipsum_dolor.py',
            category => 'lorem',
            name => 'ipsum_dolor',
        });
    $t->get_ok('/api/v1/experimental/search?q=ipsum', 'search successful');
    $t->json_is('/error' => undef, 'no errors');
    $t->json_is(
        '/data/0' => {
            occurrence => 'lorem',
            contents => "tests/lorem/ipsum.pm\n" . "tests/lorem/ipsum_dolor.py"
        },
        'job module found'
    );
    $t->json_is(
        '/data/1' => undef,
        'no additional job module found'
    );
};

subtest 'Job templates' => sub {
    my $schema = $t->app->schema;
    my $group = $schema->resultset('JobGroups')->create({name => 'Cool Group'});
    my $product = $schema->resultset('Products')
      ->create({name => 'Awesome Product', arch => 'arm64', distri => 'AwesomeOS', flavor => 'cherry'});
    my $test_suites = $schema->resultset('TestSuites');
    my $test_suite_banana = $test_suites->create({name => 'banana'});
    my $machine = $schema->resultset('Machines')->create({name => 'arm64', backend => 'qemu'});
    my $job_templates = $schema->resultset('JobTemplates');
    $job_templates->create(
        {
            name => 'fancy-example',
            description => 'Very posh',
            group_id => $group->id,
            product_id => $product->id,
            test_suite_id => $test_suite_banana->id,
            machine_id => $machine->id
        });
    $t->get_ok('/api/v1/experimental/search?q=fancy', 'search successful');
    $t->json_is('/error' => undef, 'no errors');
    $t->json_is(
        '/data/0' => {occurrence => 'Cool Group', contents => "fancy-example\nVery posh"},
        'job template found'
    );
    $t->json_is(
        '/data/1' => undef,
        'no additional job template found'
    );

    my $test_suite_apple = $test_suites->create({name => 'apple'});
    $job_templates->create(
        {
            group_id => $group->id,
            product_id => $product->id,
            test_suite_id => $test_suite_apple->id,
            machine_id => $machine->id
        });
    $t->get_ok('/api/v1/experimental/search?q=apple', 'search successful');
    $t->json_is('/error' => undef, 'no errors');
    $t->json_is(
        '/data/0' => {occurrence => 'Cool Group', contents => "apple\n"},
        'job template was found by using test suite name'
    );
};

subtest 'Limits' => sub {
    $t->app->config->{global}->{search_results_limit} = 1;
    $t->get_ok('/api/v1/experimental/search?q=test', 'Extensive search with limit')->status_is(200);
    $t->json_is('/data/1' => undef, 'capped at one match');
};

subtest 'Errors' => sub {
    $t->get_ok('/api/v1/experimental/search', 'Search succesful');
    $t->json_is('/error' => 'Erroneous parameters (q missing)', 'no search terms results in error');

    $t->get_ok('/api/v1/experimental/search?q=*', 'wildcard is interpreted literally');
    $t->json_is(
        '/data/0' => {
            occurrence => "opensuse\/tests\/openQA\/search.py",
            contents => "    1 from testapi import *",
        },
        '* finds literal *'
    );

    $t->app->config->{rate_limits}->{search} = 3;
    $t->get_ok('/api/v1/experimental/search?q=timezone', 'Search succesful') for (1 .. 3);
    $t->json_is('/error' => 'Rate limit exceeded', 'rate limit triggered');
};

done_testing();
