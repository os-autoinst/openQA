# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use Test::MockModule;
use OpenQA::Test::TimeLimit '20';
use OpenQA::Test::Case;
use OpenQA::Test::Client 'client';
use OpenQA::WebAPI::Controller::API::V1::JobTemplate;
use Mojo::File 'path';
use Mojo::IOLoop;
use OpenQA::YAML qw(load_yaml dump_yaml);

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 03-users.pl 04-products.pl');

my $accept_yaml = {Accept => 'text/yaml'};
my $t = client(Test::Mojo->new('OpenQA::WebAPI'), apikey => 'ARTHURKEY01', apisecret => 'EXCALIBUR');

my $schema = $t->app->schema;
my $job_groups = $schema->resultset('JobGroups');
my $job_templates = $schema->resultset('JobTemplates');
my $test_suites = $schema->resultset('TestSuites');
my $audit_events = $schema->resultset('AuditEvents');

my $job_template3 = {
    'test_suite' => {
        'name' => 'kde',
        'id' => 1002
    },
    'id' => 3,
    'group_name' => 'opensuse',
    'machine' => {
        'name' => '64bit',
        'id' => 1002
    },
    'prio' => 40,
    'product' => {
        'version' => '13.1',
        'flavor' => 'DVD',
        'distri' => 'opensuse',
        'id' => 1,
        'group' => 'opensuse-13.1-DVD',
        'arch' => 'i586'
    }};
$t->get_ok('/api/v1/job_templates')->status_is(200);
is_deeply(
    $t->tx->res->json,
    {
        'JobTemplates' => [
            {
                'group_name' => 'opensuse',
                'id' => 1,
                'test_suite' => {
                    'name' => 'textmode',
                    'id' => 1001
                },
                'prio' => 40,
                'machine' => {
                    'name' => '32bit',
                    'id' => 1001
                },
                'product' => {
                    'distri' => 'opensuse',
                    'version' => '13.1',
                    'flavor' => 'DVD',
                    'arch' => 'i586',
                    'group' => 'opensuse-13.1-DVD',
                    'id' => 1
                }
            },
            {
                'product' => {
                    'distri' => 'opensuse',
                    'version' => '13.1',
                    'flavor' => 'DVD',
                    'group' => 'opensuse-13.1-DVD',
                    'arch' => 'i586',
                    'id' => 1
                },
                'machine' => {
                    'name' => '64bit',
                    'id' => 1002
                },
                'prio' => 40,
                'id' => 2,
                'test_suite' => {
                    'id' => 1001,
                    'name' => 'textmode'
                },
                'group_name' => 'opensuse'
            },
            $job_template3,
            {
                'machine' => {
                    'name' => '32bit',
                    'id' => 1001
                },
                'prio' => 40,
                'product' => {
                    'id' => 1,
                    'arch' => 'i586',
                    'group' => 'opensuse-13.1-DVD',
                    'flavor' => 'DVD',
                    'version' => '13.1',
                    'distri' => 'opensuse'
                },
                'id' => 4,
                'test_suite' => {
                    'id' => 1014,
                    'name' => 'client1'
                },
                'group_name' => 'opensuse'
            },
            {
                'test_suite' => {
                    'name' => 'client2',
                    'id' => 1016
                },
                'id' => 5,
                'group_name' => 'opensuse',
                'prio' => 40,
                'machine' => {
                    'name' => '32bit',
                    'id' => 1001
                },
                'product' => {
                    'distri' => 'opensuse',
                    'flavor' => 'DVD',
                    'version' => '13.1',
                    'arch' => 'i586',
                    'group' => 'opensuse-13.1-DVD',
                    'id' => 1
                }
            },
            {
                'machine' => {
                    'name' => '32bit',
                    'id' => 1001
                },
                'prio' => 40,
                'product' => {
                    'distri' => 'opensuse',
                    'flavor' => 'DVD',
                    'version' => '13.1',
                    'group' => 'opensuse-13.1-DVD',
                    'arch' => 'i586',
                    'id' => 1
                },
                'test_suite' => {
                    'id' => 1015,
                    'name' => 'server'
                },
                'id' => 6,
                'group_name' => 'opensuse'
            },
            {
                'group_name' => 'opensuse',
                'test_suite' => {
                    'name' => 'client1',
                    'id' => 1014
                },
                'id' => 7,
                'prio' => 40,
                'machine' => {
                    'name' => '64bit',
                    'id' => 1002
                },
                'product' => {
                    'version' => '13.1',
                    'flavor' => 'DVD',
                    'distri' => 'opensuse',
                    'id' => 1,
                    'group' => 'opensuse-13.1-DVD',
                    'arch' => 'i586'
                }
            },
            {
                'group_name' => 'opensuse',
                'test_suite' => {
                    'name' => 'client2',
                    'id' => 1016
                },
                'id' => 8,
                'product' => {
                    'id' => 1,
                    'group' => 'opensuse-13.1-DVD',
                    'arch' => 'i586',
                    'version' => '13.1',
                    'flavor' => 'DVD',
                    'distri' => 'opensuse'
                },
                'prio' => 40,
                'machine' => {
                    'name' => '64bit',
                    'id' => 1002
                }
            },
            {
                'group_name' => 'opensuse',
                'id' => 9,
                'test_suite' => {
                    'name' => 'server',
                    'id' => 1015
                },
                'prio' => 40,
                'machine' => {
                    'name' => '64bit',
                    'id' => 1002
                },
                'product' => {
                    'arch' => 'i586',
                    'group' => 'opensuse-13.1-DVD',
                    'id' => 1,
                    'distri' => 'opensuse',
                    'flavor' => 'DVD',
                    'version' => '13.1'
                }
            },
            {
                'product' => {
                    'distri' => 'opensuse',
                    'flavor' => 'DVD',
                    'version' => '13.1',
                    'arch' => 'i586',
                    'group' => 'opensuse-13.1-DVD',
                    'id' => 1
                },
                'prio' => 40,
                'machine' => {
                    'id' => 1002,
                    'name' => '64bit'
                },
                'group_name' => 'opensuse',
                'test_suite' => {
                    'name' => 'advanced_kde',
                    'id' => 1017
                },
                'settings' => [{key => 'ADVANCED', value => '1'}, {key => 'DESKTOP', value => 'advanced_kde'},],
                'id' => 10,
            }]
    },
    "Initial job templates"
) || diag explain $t->tx->res->json;

subtest 'to_yaml' => sub {
    my $yaml1 = path("$FindBin::Bin/../data/08-opensuse.yaml")->slurp;
    my $yaml2 = path("$FindBin::Bin/../data/08-opensuse-test.yaml")->slurp;
    my %yaml = (1001 => $yaml1, 1002 => $yaml2);

    my @templates;
    for my $group ($job_groups->search) {
        my $id = $group->id;
        my $yaml = $group->to_yaml;
        cmp_ok($yaml, 'eq', $yaml{$group->id}, "group($id)->to_yaml");
    }
};

subtest 'missing-linebreak' => sub {
    my $orig = OpenQA::Schema::Result::JobGroups->can('to_yaml');
    my $mock = Test::MockModule->new('OpenQA::Schema::Result::JobGroups');
    # Code should be able to deal with YAML missing last linebreak
    $mock->redefine(
        to_yaml => sub {
            my ($self) = @_;
            my $yaml = $orig->($self);
            chomp $yaml;
            return $yaml;
        });
    $t->get_ok("/api/v1/job_templates_scheduling")->status_is(200);
    my $yaml = $t->tx->res->json;
    is_deeply(['opensuse', 'opensuse test'], [sort keys %$yaml], 'YAML of all groups contains names')
      || diag explain $t->tx->res->body;
};

$t->post_ok(
    '/api/v1/job_templates',
    form => {
        group_id => 1001,
        machine_id => 1001,
        test_suite_id => 1002,
        product_id => 1,
        prio => 30,
        description => 'descr',
    })->status_is(200);
my $job_template_id1 = $t->tx->res->json->{id};
ok($job_template_id1, "Created job template ($job_template_id1)");

$t->post_ok(
    '/api/v1/job_templates',
    form => {
        group_name => 'opensuse',
        machine_name => '64bit',
        test_suite_name => 'RAID0',
        arch => 'i586',
        distri => 'opensuse',
        flavor => 'DVD',
        version => '13.1',
        prio => 20
    })->status_is(200);
my $job_template_id2 = $t->tx->res->json->{id};
ok($job_template_id2, "Created job template ($job_template_id2)");
is_deeply(
    OpenQA::Test::Case::find_most_recent_event($t->app->schema, 'jobtemplate_create'),
    {ids => [$job_template_id2], id => 12},
    'Create was logged correctly'
);

subtest 'Lookup job templates' => sub {
    my $job_template1 = {
        'id' => $job_template_id1,
        'group_name' => 'opensuse',
        'machine' => {
            'id' => 1001,
            'name' => '32bit'
        },
        'prio' => 30,
        'product' => {
            'arch' => 'i586',
            'distri' => 'opensuse',
            'flavor' => 'DVD',
            'id' => 1,
            'version' => '13.1',
            'group' => 'opensuse-13.1-DVD',
        },
        'test_suite' => {
            'id' => 1002,
            'name' => 'kde'
        },
    };
    $t->get_ok("/api/v1/job_templates/$job_template_id1")->status_is(200)->json_is(
        '/JobTemplates/0' => $job_template1,
        "Found job template $job_template_id1 by its ID"
    );
    diag explain $t->tx->res->json unless $t->success;

    my $job_template2 = {
        'group_name' => 'opensuse',
        'prio' => 20,
        'test_suite' => {
            'id' => 1013,
            'name' => 'RAID0'
        },
        'machine' => {
            'id' => 1002,
            'name' => '64bit'
        },
        'product' => {
            'arch' => 'i586',
            'version' => '13.1',
            'id' => 1,
            'group' => 'opensuse-13.1-DVD',
            'distri' => 'opensuse',
            'flavor' => 'DVD'
        },
        'id' => $job_template_id2
    };
    $t->get_ok("/api/v1/job_templates/$job_template_id2")->status_is(200)->json_is(
        '/JobTemplates/0' => $job_template2,
        "Found job template $job_template_id2 by its ID"
    );
    diag explain $t->tx->res->json unless $t->success;

    $t->get_ok(
        "/api/v1/job_templates",
        form => {
            machine_name => '64bit',
            test_suite_name => 'RAID0',
            'arch' => 'i586',
            'distri' => 'opensuse',
            'flavor' => 'DVD',
            'version' => '13.1'
        }
    )->status_is(200)->json_is(
        '/JobTemplates/0' => $job_template2,
        'Found job template by name'
    );
    diag explain $t->tx->res->json unless $t->success;

    $t->get_ok("/api/v1/job_templates", form => {test_suite_name => 'kde'})->status_is(200)->json_is(
        '/JobTemplates' => [$job_template3, $job_template1],
        'Found job templates with test suite kde'
    );
    diag explain $t->tx->res->json unless $t->success;
};

subtest 'Changing priority' => sub {
    for my $prio (15, undef) {
        $t->post_ok(
            '/api/v1/job_templates',
            form => {
                group_id => 1001,
                test_suite_id => 1002,
                prio => 15,
            }
        )->status_is(400)->json_is(
            '/error' =>
'Erroneous parameters (arch missing, distri missing, flavor missing, group_name missing, machine_name missing, test_suite_name missing, version missing)',
            'setting prio for group/testsuite requires prio-only parameter'
        );
        is($job_templates->search({prio => $prio})->count, 0, 'no rows affected');

        $t->post_ok(
            '/api/v1/job_templates',
            form => {
                group_id => 1001,
                test_suite_id => 1002,
                prio => $prio // 'inherit',
                prio_only => 1,
            })->status_is(200)->json_is('' => {job_group_id => 1001, ids => [3, 11]}, 'two rows affected');
        is($job_templates->search({prio => $prio})->count, 2, 'two rows now have prio ' . ($prio // 'inherit'));
        is_deeply(
            OpenQA::Test::Case::find_most_recent_event($t->app->schema, 'jobtemplate_create'),
            {job_group_id => 1001, ids => [3, 11]},
            'Create was logged correctly'
        );
    }

    for my $prio ('-5', "30\n") {
        $t->post_ok(
            '/api/v1/job_templates',
            form => {
                group_id => 1001,
                test_suite_id => 1002,
                prio => $prio,
                prio_only => 1,
            }
        )->status_is(400)
          ->json_is('/error' => 'Erroneous parameters (prio invalid)', "setting prio to '$prio' is an error");
        is($job_templates->search({prio => $prio})->count, 0, 'no rows affected');
    }
};

my $product = 'open-*.SUSE1';
my $yaml = {};
my $schema_filename = 'JobTemplates-01.yaml';
is_deeply(scalar @{$t->app->validate_yaml($yaml, $schema_filename, 1)}, 2, 'Empty YAML is an error')
  or diag explain dump_yaml(string => $yaml);
$yaml->{scenarios}{'x86_64'}{$product} = ['spam', 'eggs'];
is_deeply($t->app->validate_yaml($yaml, $schema_filename, 1), ["/products: Missing property."], 'No products defined')
  or diag explain dump_yaml(string => $yaml);
$yaml->{products}{$product} = {version => '42.1', flavor => 'DVD'};
is_deeply(
    @{$t->app->validate_yaml($yaml, $schema_filename, 1)}[0],
    "/products/$product/distri: Missing property.",
    'No distri specified'
) or diag explain dump_yaml(string => $yaml);
$yaml->{products}{$product}{distri} = 'sle';
delete $yaml->{products}{$product}{flavor};
is_deeply(
    @{$t->app->validate_yaml($yaml, $schema_filename, 1)}[0],
    "/products/$product/flavor: Missing property.",
    'No flavor specified'
) or diag explain dump_yaml(string => $yaml);
$yaml->{products}{$product}{flavor} = 'DVD';
delete $yaml->{products}{$product}{version};
is_deeply(
    $t->app->validate_yaml($yaml, $schema_filename, 1),
    ["/products/$product/version: Missing property."],
    'No version specified'
) or diag explain dump_yaml(string => $yaml);
$yaml->{products}{$product}{distribution} = 'sle';
is_deeply(
    @{$t->app->validate_yaml($yaml, $schema_filename, 1)}[0],
    "/products/$product: Properties not allowed: distribution.",
    'Invalid product property specified'
) or diag explain dump_yaml(string => $yaml);
delete $yaml->{products}{$product}{distribution};
$yaml->{products}{$product}{version} = '42.1';
# Add non-trivial test suites to exercise the validation
$yaml->{scenarios}{'x86_64'}{$product} = [
    'spam',
    "eg-G_S +133t*.\t",
    {
        'foo' => {},
    },
    {
        "b-A_RRRR +133t*.\t" => {
            machine => 'x86_64',
            priority => 33,
        },
    }];
is_deeply($t->app->validate_yaml($yaml, $schema_filename, 1), [], 'YAML valid as expected')
  or diag explain dump_yaml(string => $yaml);
my $opensuse = $job_groups->find({name => 'opensuse'});
# Make 40 our default priority, which matters when we look at the "defaults" key later
$opensuse->update({default_priority => 40});
# Get all groups
$t->get_ok("/api/v1/job_templates_scheduling")->status_is(200);
$yaml = $t->tx->res->json;
is_deeply(['opensuse', 'opensuse test'], [sort keys %$yaml], 'YAML of all groups contains names')
  || diag explain $t->tx->res->body;
# Get one group with defined scenarios, products and defaults
$t->get_ok('/api/v1/job_templates_scheduling/' . $opensuse->id)->status_is(200);
#$yaml = $t->tx->res->body;
# this test seems to be a tautology ;-)
#is($t->tx->res->body, $yaml, 'No document start marker by default');
$yaml = load_yaml(string => $t->tx->res->json);
is_deeply($t->app->validate_yaml($yaml, $schema_filename, 1), [], 'YAML of single group is valid');
my $yaml2 = load_yaml(file => "$FindBin::Bin/../data/08-opensuse-2.yaml");
is_deeply($yaml, $yaml2, 'YAML for opensuse group') || diag explain $t->tx->res->body;

subtest 'content-type' => sub {
    $t->get_ok('/api/v1/job_templates_scheduling/' . $opensuse->id, $accept_yaml)->status_is(200)
      ->content_type_is('text/yaml;charset=UTF-8');
    is_deeply(load_yaml(string => $t->tx->res->body),
        $yaml, '[Accept: text/yaml] Test suite with unicode characters encoded correctly')
      || diag explain $t->tx->res->body;

    $t->get_ok('/api/v1/job_templates_scheduling/' . $opensuse->id, {Accept => '*/*'})->status_is(200)
      ->content_type_is('text/yaml;charset=UTF-8');
    is_deeply(load_yaml(string => $t->tx->res->body),
        $yaml, '[Accept: */*] Test suite with unicode characters encoded correctly')
      || diag explain $t->tx->res->body;

    $t->get_ok('/api/v1/job_templates_scheduling/' . $opensuse->id, {Accept => 'application/json'})->status_is(200)
      ->content_type_is('application/json;charset=UTF-8');
    is_deeply(load_yaml(string => $t->tx->res->json),
        $yaml, '[Accept: application/json] Test suite with unicode characters encoded correctly')
      || diag explain $t->tx->res->body;

    $t->get_ok('/api/v1/job_templates_scheduling/' . $opensuse->id)->status_is(200)
      ->content_type_is('application/json;charset=UTF-8');
    is_deeply(load_yaml(string => $t->tx->res->json),
        $yaml, '[no explicit Accept header] Test suite with unicode characters encoded correctly')
      || diag explain $t->tx->res->body;

    $t->get_ok('/api/v1/job_templates_scheduling', $accept_yaml)->status_is(200)
      ->content_type_is('text/yaml;charset=UTF-8');
    my $yaml = load_yaml(string => $t->tx->res->body);
    is_deeply(
        ['opensuse', 'opensuse test'],
        [sort keys %$yaml],
        '[Accept: text/yaml] YAML of all groups contains names'
    ) || diag explain $t->tx->res->body;

    $t->get_ok('/api/v1/job_templates_scheduling', {Accept => '*/*'})->status_is(200)
      ->content_type_is('text/yaml;charset=UTF-8');
    $yaml = load_yaml(string => $t->tx->res->body);
    is_deeply(
        ['opensuse', 'opensuse test'],
        [sort keys %$yaml],
        '[Accept: text/yaml] YAML of all groups contains names'
    ) || diag explain $t->tx->res->body;

    $t->get_ok('/api/v1/job_templates_scheduling', {Accept => 'application/json'})->status_is(200)
      ->content_type_is('application/json;charset=UTF-8');
    $yaml = $t->tx->res->json;
    is_deeply(
        ['opensuse', 'opensuse test'],
        [sort keys %$yaml],
        '[Accept: application/json] YAML of all groups contains names'
    ) || diag explain $t->tx->res->body;

    $t->get_ok('/api/v1/job_templates_scheduling')->status_is(200)->content_type_is('application/json;charset=UTF-8');
    $yaml = $t->tx->res->json;
    is_deeply(
        ['opensuse', 'opensuse test'],
        [sort keys %$yaml],
        '[no explicit Accept header] YAML of all groups contains names'
    ) || diag explain $t->tx->res->body;
};

subtest 'Migration' => sub {
    # Legacy group was created with no YAML
    is($opensuse->template, undef, 'No YAML stored in the database');

    # After posting YAML the exact template is stored
    $yaml = dump_yaml(string => $yaml);
    $t->post_ok(
        '/api/v1/job_templates_scheduling/' . $opensuse->id,
        form => {
            schema => $schema_filename,
            template => $yaml
        })->status_is(200, 'YAML added to the database');
    return diag explain $t->tx->res->body unless $t->success;
    $opensuse->discard_changes;
    is($opensuse->template, $yaml, 'YAML stored in the database');
    $yaml = "# comments help readability\n$yaml# or in the end\n";
    $t->post_ok(
        '/api/v1/job_templates_scheduling/' . $opensuse->id,
        form => {
            schema => $schema_filename,
            template => $yaml
        })->status_is(200, 'YAML with comments posted');
    $t->get_ok('/api/v1/job_templates_scheduling/' . $opensuse->id);
    is($t->tx->res->json, $yaml, 'YAML with comments preserved in the database');
};

subtest 'Deprecated routes still work' => sub {
    $t->post_ok(
        '/api/v1/experimental/job_templates_scheduling/' . $opensuse->id,
        form => {
            schema => $schema_filename,
            template => $yaml
        })->status_is(200, 'YAML posted successfully');
    $t->get_ok('/api/v1/experimental/job_templates_scheduling/' . $opensuse->id);
    is($t->tx->res->json, $yaml, 'YAML retrieved from the database');
};

subtest 'Conflicts' => sub {
    $t->post_ok(
        '/api/v1/job_templates_scheduling/' . $opensuse->id,
        form => {
            schema => $schema_filename,
            reference => 'some invalid yaml',
            template => $yaml,
        }
    )->json_is(
        '' => {
            error_status => 400,
            error => ['Template was modified',],
            id => $opensuse->id,
            job_group_id => $opensuse->id,
            template => $yaml,
        },
        'posting with wrong reference fails'
    );

    # Remove the trailing line-break which should not break validation
    ok($yaml =~ m/\n\z/, 'YAML has trailing line-break');
    chomp $yaml;
    ok($yaml !~ m/\n\z/, 'YAML has no trailing line-break');

    $t->post_ok(
        '/api/v1/job_templates_scheduling/' . $opensuse->id,
        form => {
            schema => $schema_filename,
            reference => $yaml,
            template => $yaml,
        })->status_is(200, 'posting with correct reference succeeds');
    return diag explain $t->tx->res->body unless $t->success;
    my $saved_yaml = $t->tx->res->json->{template};
    ok($saved_yaml =~ m/\n\z/, 'Saved YAML has trailing line-break') or diag explain $saved_yaml;

    $t->post_ok(
        '/api/v1/job_templates_scheduling/' . $opensuse->id,
        form => {
            schema => $schema_filename,
            reference => $saved_yaml,
            template => $yaml,
        })->status_is(200, 're-posting the result as a reference succeeds');
    diag explain $t->tx->res->body unless $t->success;
};

my $template = {};
subtest 'Schema handling' => sub {
    for my $schema_filename (undef, 'NoSuchSchema', '../test.yaml', '/home/test.yaml', 'NoSuchSchema.yaml') {
        is_deeply(scalar @{$t->app->validate_yaml($yaml, $schema_filename, 1)},
            1, 'Validating with schema ' . ($schema_filename // 'undefined') . ' is an error')
          or diag explain dump_yaml(string => $yaml);
    }

    for my $schema_filename ('NoSuchSchema', '../test.yaml', '/home/test.yaml') {
        $t->post_ok(
            '/api/v1/job_templates_scheduling/' . $opensuse->id,
            form => {
                template => dump_yaml(string => $template),
                schema => $schema_filename,
            }
        )->status_is(400)->json_is(
            '/error' => 'Erroneous parameters (schema invalid)',
            "posting YAML template with schema $schema_filename fails"
        );
        diag explain $t->tx->res->body unless $t->success;
    }

    $t->post_ok(
        '/api/v1/job_templates_scheduling/' . $opensuse->id,
        form => {
            template => dump_yaml(string => $template),
        }
    )->status_is(400)->json_is(
        '/error' => 'Erroneous parameters (schema missing)',
        'posting YAML template with no schema fails'
    );
    diag explain $t->tx->res->body unless $t->success;

    $t->post_ok(
        '/api/v1/job_templates_scheduling/' . $opensuse->id,
        form => {
            template => dump_yaml(string => $template),
            schema => 'NoSuchSchema.yaml',
        })->status_is(400)->json_like('/error/0' => qr/Unable to load schema/, 'specified schema not found');
};

# Attempting to modify group with erroneous YAML should fail
$t->post_ok(
    '/api/v1/job_templates_scheduling/' . $opensuse->id,
    form => {
        schema => $schema_filename,
        template => dump_yaml(string => $template)})->status_is(400);
my $json = $t->tx->res->json;
my @errors = ref($json->{error}) eq 'ARRAY' ? sort { $a->{path} cmp $b->{path} } @{$json->{error}} : ();
is($json->{error_status}, 400, 'posting invalid YAML template results in error');
is_deeply(
    \@errors,
    [{path => '/products', message => 'Missing property.'}, {path => '/scenarios', message => 'Missing property.'},],
    'expected error messages returned'
) or diag explain $json;

my $template_yaml = path("$FindBin::Bin/../data/08-testsuite-multiple-keys.yaml")->slurp;
# Assure that testsuite hashes with more than one key are detected as invalid
$t->post_ok(
    '/api/v1/job_templates_scheduling/' . $opensuse->id,
    form => {
        schema => $schema_filename,
        template => $template_yaml,
    },
)->status_is(400)->json_is(
    '/error_status' => 400,
    'posting invalid YAML template - error_status',
)->json_is(
    '/error/0/path' => '/scenarios/i586/opensuse-13.1-DVD-i586/0',
    'posting invalid YAML template - error path',
)->json_like(
    # Depends on JSON::Validator version; started to change in JSON::Validator 3.24
    '/error/0/message' => qr{/anyOf/1 Too many properties: 2/1.|/anyOf/0 Expected string - got object.},
    'posting invalid YAML template - error content',
);

subtest 'Create and modify groups with YAML' => sub {
    my $job_group_id3 = $job_groups->create({name => 'foo'})->id;
    ok($job_group_id3, "Created group foo ($job_group_id3)");

    # Create group and job templates based on YAML template
    $yaml = load_yaml(file => "$FindBin::Bin/../data/08-create-modify-group.yaml");
    $t->post_ok(
        "/api/v1/job_templates_scheduling/$job_group_id3",
        form => {
            schema => $schema_filename,
            template => dump_yaml(string => $yaml)}
    )->status_is(400, 'Post rejected because testsuite does not exist')->json_is(
        '' => {
            error => ['Testsuite \'eggs\' is invalid'],
            error_status => 400,
            id => $job_group_id3,
            job_group_id => $job_group_id3,
        },
        'Invalid testsuite'
    );
    return diag explain $t->tx->res->body unless $t->success;

    # Add required testsuites
    for my $test_suite_name (qw(foobar spam eggs)) {
        $test_suites->create({name => $test_suite_name});
    }

    # Assert that nothing changes in preview mode
    my $audit_event_count = $audit_events->count;
    $t->post_ok(
        "/api/v1/job_templates_scheduling/$job_group_id3",
        form => {
            schema => $schema_filename,
            preview => 1,
            expand => 1,
            template => dump_yaml(string => $yaml),
        });
    $t->status_is(200, 'Posting preview successful');
    is_deeply(
        load_yaml(string => load_yaml(string => $t->tx->res->body)->{result}),
        {
            products => {
                'opensuse-13.1-DVD-i586' => {
                    distri => 'opensuse',
                    flavor => 'DVD',
                    version => '13.1',
                }
            },
            scenarios => {
                i586 => {
                    'opensuse-13.1-DVD-i586' => [
                        {
                            eggs => {
                                machine => '32bit',
                                priority => 20,
                                settings => {BAR => 'updated later', FOO => 'removed later'},
                            }
                        },
                        {
                            foobar => {
                                machine => '64bit',
                                priority => 40,
                                settings => {},
                            }
                        },
                        {
                            spam => {
                                machine => '64bit',
                                priority => 40,
                                settings => {},
                            }
                        },
                    ]}
            },
        },
        'Expected result returned in response'
    ) || diag explain $t->tx->res->body;
    $t->get_ok("/api/v1/job_templates_scheduling/$job_group_id3");
    is_deeply(
        load_yaml(string => $t->tx->res->json),
        {scenarios => {}, products => {}},
        'No job group and templates added to the database'
    ) || diag explain $t->tx->res->body;
    is($audit_events->count, $audit_event_count, 'no audit event emitted in preview mode');

    $t->post_ok(
        "/api/v1/job_templates_scheduling/$job_group_id3",
        form => {
            schema => $schema_filename,
            template => dump_yaml(string => $yaml)});
    $t->status_is(200, 'Changes applied to the database');
    return diag explain $t->tx->res->body unless $t->success;
    $t->get_ok("/api/v1/job_templates_scheduling/$job_group_id3");
    is_deeply(load_yaml(string => $t->tx->res->json), $yaml, 'Added job template reflected in the database')
      || diag explain $t->tx->res->body;

    subtest 'Modify test attributes in group according to YAML template' => sub {
        $yaml->{defaults}{i586}{settings} = {BAR => 'unused default', FOO => 'default'};
        my %foobar_definition = (
            priority => 11,
            machine => '32bit',
            settings => {
                BAR => 'updated value',
                NEW => 'new setting',
            },
        );
        $yaml->{scenarios}{i586}{'opensuse-13.1-DVD-i586'} = [{foobar => \%foobar_definition}, 'spam', 'eggs'];
        $t->post_ok(
            "/api/v1/job_templates_scheduling/$job_group_id3",
            form => {
                schema => $schema_filename,
                template => dump_yaml(string => $yaml)})->status_is(200, 'Test suite was updated');

        my $job_template = $job_templates->find({prio => 11});
        is($job_template->machine_id, 1001, 'Updated machine reflected in the database');
        is_deeply(
            $job_template->settings_hash,
            {FOO => 'default', BAR => 'updated value', NEW => 'new setting'},
            'Modified attributes reflected in the database'
        );
    };

    subtest 'Scenarios must be be unique across job groups' => sub {
        $yaml->{scenarios}{i586}{'opensuse-13.1-DVD-i586'} = ['textmode'];
        $t->post_ok(
            "/api/v1/job_templates_scheduling/$job_group_id3",
            form => {
                schema => $schema_filename,
                template => dump_yaml(string => $yaml)}
        )->status_is(400, 'Post rejected because scenarios are ambiguous')->json_is(
            '' => {
                error => [
'Job template name \'textmode\' with opensuse-13.1-DVD-i586 and 64bit is already used in job group \'opensuse\''
                ],
                error_status => 400,
                id => $job_group_id3,
                job_group_id => $job_group_id3,
            },
            'Invalid testsuite'
        );
    };

    subtest 'empty-testsuite' => sub {
        my $template_yaml = path("$FindBin::Bin/../data/08-testsuite-null.yaml")->slurp;

        $schema->txn_begin;
        $t->post_ok(
            '/api/v1/job_templates_scheduling/' . $opensuse->id,
            form => {
                schema => $schema_filename,
                template => $template_yaml,
            },
        )->status_is(200, 'Posting template with "testsuite: null"');

        my $empty_testsuite
          = $test_suites->find({name => OpenQA::Schema::ResultSet::JobTemplates::EMPTY_TESTSUITE_NAME});
        is(
            $empty_testsuite->description,
            OpenQA::Schema::ResultSet::JobTemplates::EMPTY_TESTSUITE_DESCRIPTION,
            'Empty testsuite description ok'
        );
        is($job_templates->search({test_suite_id => $empty_testsuite->id})->count, 1, 'one row has empty testsuite');
        is($job_templates->search({prio => 97})->count, 1, 'one row has prio 97');
        $schema->txn_rollback;
    };

    subtest 'testsuite-with-merge-keys' => sub {
        my $template_yaml = path("$FindBin::Bin/../data/08-merge.yaml")->slurp;
        my $exp_yaml = path("$FindBin::Bin/../data/08-merge-expanded.yaml")->slurp;

        $schema->txn_begin;
        $t->post_ok(
            '/api/v1/job_templates_scheduling/' . $opensuse->id,
            form => {
                schema => $schema_filename,
                template => $template_yaml,
            },
        )->status_is(200, 'Posting template with merge keys');

        $t->get_ok("/api/v1/job_templates_scheduling/" . $opensuse->id);
        # Prepare expected result
        is_deeply(
            load_yaml(string => $t->tx->res->json),
            load_yaml(string => $exp_yaml),
            'YAML with merge keys equals YAML with resolved merge keys'
        ) || diag explain $t->tx->res->body;

        $schema->txn_rollback;
    };


    subtest 'Multiple scenarios with different variables' => sub {
        # Define more than one scenario with the same testsuite
        my %foo_spam = (
            settings => {
                FOO => 'spam',
            },
        );
        my %foo_eggs = (
            settings => {
                FOO => 'eggs',
            },
        );
        $yaml->{scenarios}{i586}{'opensuse-13.1-DVD-i586'} = [{foobar => \%foo_spam}, {foobar => \%foo_eggs}];
        $t->post_ok(
            "/api/v1/job_templates_scheduling/$job_group_id3",
            form => {
                schema => $schema_filename,
                template => dump_yaml(string => $yaml)}
        )->status_is(400, 'Post rejected because scenarios are ambiguous')->json_is(
            '' => {
                error => [
                        'Job template name \'foobar\' is defined more than once. '
                      . 'Use a unique name and specify \'testsuite\' to re-use test suites in multiple scenarios.'
                ],
                error_status => 400,
                id => $job_group_id3,
                job_group_id => $job_group_id3,
            },
            'Invalid testsuite'
        );

        # Specify testsuite to correctly disambiguate
        %foo_eggs = (
            testsuite => 'foobar',
            settings => {
                FOO => 'eggs',
            },
        );
        $yaml->{scenarios}{i586}{'opensuse-13.1-DVD-i586'} = [{foobar => \%foo_spam}, {foobar_eggs => \%foo_eggs}];
        $yaml->{defaults}{i586}{'priority'} = 16;
        $t->post_ok(
            "/api/v1/job_templates_scheduling/$job_group_id3",
            form => {
                schema => $schema_filename,
                template => dump_yaml(string => $yaml)})->status_is(200);
        return diag explain $t->tx->res->body unless $t->success;
        if (!is($job_templates->search({prio => 16})->count, 2, 'two distinct job templates')) {
            my $jt = $job_templates->search({prio => 16});
            while (my $j = $jt->next) {
                diag explain dump_yaml(string => $j->to_hash);
            }
        }
        my %new_isos_post_params = (
            _GROUP => 'foo',
            DISTRI => 'opensuse',
            VERSION => '13.1',
            FLAVOR => 'DVD',
            ARCH => 'i586',
        );
        $t->post_ok('/api/v1/isos', form => \%new_isos_post_params)->status_is(200, 'ISO posted');
        return diag explain $t->tx->res->body unless $t->success;
        my $jobs = $schema->resultset('Jobs');
        my %tests = map { $_ => $jobs->find($_)->settings_hash->{'NAME'} } @{$t->tx->res->json->{ids}};
        is_deeply(
            [sort values %tests],
            ['00099982-opensuse-13.1-DVD-i586-foobar@64bit', '00099983-opensuse-13.1-DVD-i586-foobar_eggs@64bit',],
            'Jobs created'
        );
    };

    subtest 'Post unmodified job template' => sub {
        $t->post_ok(
            "/api/v1/job_templates_scheduling/$job_group_id3",
            form => {
                schema => $schema_filename,
                template => dump_yaml(string => $yaml)}
        )->status_is(200)->json_is(
            '' => {
                id => $job_group_id3,
                job_group_id => $job_group_id3,
                ids => [25, 26],
            },
            'No-op import of existing job template'
        );
        $t->get_ok("/api/v1/job_templates_scheduling/$job_group_id3");
        is_deeply(load_yaml(string => $t->tx->res->json), $yaml, 'Unmodified group should not result in any changes')
          || diag explain $t->tx->res->body;
    };

    subtest 'Single scenario with multiple machines' => sub {
        $test_suites->create({name => 'baz'});
        $yaml->{defaults}{i586}{'machine'} = ['Laptop_64', '64bit'];
        $yaml->{scenarios}{i586}{'opensuse-13.1-DVD-i586'} = [
            {baz => {machine => ['32bit', '64bit'], priority => 7}},
            {baz_defaults => {priority => 7, testsuite => 'baz'}}];
        $t->post_ok(
            "/api/v1/job_templates_scheduling/$job_group_id3",
            form => {
                schema => $schema_filename,
                template => dump_yaml(string => $yaml)});
        return diag explain $t->tx->res->body unless $t->success;
        if (!is($job_templates->search({prio => 7})->count, 4, 'four job templates created')) {
            my $jt = $job_templates->search({prio => 7});
            while (my $j = $jt->next) {
                diag explain dump_yaml(string => $j->to_hash);
            }
        }
    };

    subtest 'Errors due to invalid properties' => sub {
        $yaml->{scenarios}{i586}{'opensuse-13.1-DVD-i586'}
          = [{foobar => {priority => 11, machine => '31bit'}}];
        $t->post_ok(
            "/api/v1/job_templates_scheduling/$job_group_id3",
            form => {
                schema => $schema_filename,
                template => dump_yaml(string => $yaml)}
        )->status_is(400)->json_is(
            '' => {
                id => $job_group_id3,
                job_group_id => $job_group_id3,
                error_status => 400,
                error => ["Machine '31bit' is invalid"],
            },
            'Invalid machine in test suite'
        );

        $yaml->{scenarios}{i586}{'opensuse-13.1-DVD-i586'} = ['foo'];
        $yaml->{defaults}{i586}{'machine'} = '66bit';
        $t->post_ok(
            "/api/v1/job_templates_scheduling/$job_group_id3",
            form => {
                schema => $schema_filename,
                template => dump_yaml(string => $yaml)}
        )->status_is(400)->json_is(
            '' => {
                id => $job_group_id3,
                job_group_id => $job_group_id3,
                error_status => 400,
                error => ["Machine '66bit' is invalid"],
            },
            'Invalid machine in defaults'
        );

        $yaml->{defaults}{i586}{'machine'} = '64bit';
        $yaml->{products}{'opensuse-13.1-DVD-i586'}{'distri'} = 'geeko';
        $t->post_ok(
            "/api/v1/job_templates_scheduling/$job_group_id3",
            form => {
                schema => $schema_filename,
                template => dump_yaml(string => $yaml)}
        )->status_is(400)->json_is(
            '' => {
                id => $job_group_id3,
                job_group_id => $job_group_id3,
                error_status => 400,
                error => ["Product 'opensuse-13.1-DVD-i586' is invalid"],
            },
            'Invalid product'
        );
    };
};

subtest 'References' => sub {
    my $job_group_id4 = $job_groups->create({name => 'test'})->id;
    ok($job_group_id4, "Created group test ($job_group_id4)");
    $yaml = load_yaml(file => "$FindBin::Bin/../data/08-refs.yaml");
    $t->post_ok(
        "/api/v1/job_templates_scheduling/$job_group_id4",
        form => {
            schema => $schema_filename,
            template => dump_yaml(string => $yaml)});
    $t->status_is(200, 'New group with references was added to the database');
    return diag explain $t->tx->res->body unless $t->success;

    $t->get_ok("/api/v1/job_templates_scheduling/$job_group_id4");
    # Prepare expected result
    @{$yaml->{scenarios}{ppc64}{'opensuse-13.1-DVD-ppc64'}} = qw(spam eggs);
    is_deeply(load_yaml(string => $t->tx->res->json),
        $yaml, 'Added group with references should be reflected in the database')
      || diag explain $t->tx->res->body;

    # Event reflects changes to the YAML
    @{$yaml->{scenarios}{ppc64}{'opensuse-13.1-DVD-ppc64'}} = qw(spam foobar);
    $t->post_ok(
        "/api/v1/job_templates_scheduling/$job_group_id4",
        form => {
            schema => $schema_filename,
            template => dump_yaml(string => $yaml)})->status_is(200);
    return diag explain $t->tx->res->body unless $t->success;

    is_deeply(
        OpenQA::Test::Case::find_most_recent_event($t->app->schema, 'jobtemplate_create'),
        {
            id => $job_group_id4,
            job_group_id => $job_group_id4,
            ids => [37, 32, 38, 34, 39, 36],
            changes => '@@ -22,7 +22,7 @@
   i586:
     opensuse-13.1-DVD-i586: &2
     - spam
-    - eggs
+    - foobar
   ppc64:
     opensuse-13.1-DVD-ppc64: *2
   x86_64:'
        },
        'Diff reflects changes in the YAML'
    );
};

subtest 'Hidden keys' => sub {
    my $job_group = $job_groups->create({name => 'hidden'});
    ok($job_group, 'Created group hidden (' . $job_group->id . ')');
    $yaml = load_yaml(file => "$FindBin::Bin/../data/08-hidden-keys.yaml");
    $t->post_ok(
        '/api/v1/job_templates_scheduling/' . $job_group->id,
        form => {
            schema => $schema_filename,
            expand => 1,
            template => dump_yaml(string => $yaml)});
    $t->status_is(200, 'New group with hidden keys was added to the database');
    return diag explain $t->tx->res->body unless $t->success;

    # Prepare expected result
    $yaml->{scenarios}{i586}{'opensuse-13.1-DVD-i586'}
      = [{kde_usb => {priority => 70, machine => '64bit', settings => {USB => '1'}}}];
    delete $yaml->{defaults};
    delete $yaml->{'.kde_template'};
    is_deeply(load_yaml(string => load_yaml(string => $t->tx->res->body)->{result}),
        $yaml, 'Added group with hidden keys should be reflected in the database')
      || diag explain $t->tx->res->body;
    # Clean up to avoid affecting other subtests
    $job_group->delete;
};

subtest 'Staging' => sub {
    $schema->resultset('Machines')->create({name => '64bit-staging', backend => 'qemu'});
    $schema->resultset('Machines')->create({name => 'uefi-staging', backend => 'qemu'});
    $schema->resultset('Machines')->create({name => 'uefi-virtio-vga', backend => 'qemu'});
    for my $letter (qw/A B C D E H S V Y/) {
        $schema->resultset('Products')->create(
            {
                distri => 'sle',
                version => '12-SP5',
                flavor => "Server-DVD-$letter-Staging",
                arch => 'x86_64',
                name => "sle-12-SP5-Server-DVD-$letter-Staging-x86_64"
            });
    }
    for my $ts (
        qw/cryptlvm RAID1 gnome cryptlvm_minimal_x minimal+base autoyast_mini_no_product default_install installcheck migration_zdup_offline_sle12sp2_64bit-staging rescue_system_sle11sp4 ext4_uefi-staging/
      )
    {
        $schema->resultset('TestSuites')->create({name => $ts});
    }
    my $job_group_id4 = $job_groups->create({name => 'staging'})->id;
    ok($job_group_id4, "Created group test ($job_group_id4)");
    # Create group based on YAML with references
    $yaml = load_yaml(file => "$FindBin::Bin/../data/08-refs-vars.yaml");
    $t->post_ok(
        "/api/v1/job_templates_scheduling/$job_group_id4",
        form => {
            schema => $schema_filename,
            template => dump_yaml(string => $yaml)});
    $t->status_is(200, 'New group with references and variables was added to the database');
    return diag explain $t->tx->res->body unless $t->success;
    $t->get_ok(
        "/api/v1/job_templates",
        form => {
            test_suite_name => 'RAID1',
            flavor => ''
        })->status_is(200);
    for my $json (@{$t->tx->res->json->{JobTemplates}}) {
        is_deeply(
            $json->{settings},
            [
                {
                    "key" => "INSTALLATION_VALIDATION",
                    "value" => ""
                },
                {
                    "key" => "INSTALLONLY",
                    "value" => ""
                },
                {
                    "key" => "YAML_SCHEDULE",
                    "value" => "schedule/staging/%TEST%\@64bit-staging.yaml"
                }
            ],
            "Correct settings for $json->{product}->{flavor}"
        );
    }
};

subtest 'Modifying tables used in YAML not allowed' => sub {
    my $job_templates = $job_templates->search({id => $job_template_id1});
    while (my $job_template = $job_templates->next) {
        $t->post_ok('/api/v1/products/' . $job_template->product_id,
            form => {arch => 'x86_64', distri => 'opensuse', flavor => 'DVD', version => 13.2})->json_is(
            '' =>
              {error_status => 400, error => 'Groups foo, opensuse, test must be updated through the YAML template'},
            'Attempt to rename product used in group was blocked'
            );
        $t->post_ok(
            '/api/v1/products/' . $job_template->product_id,
            form => {
                arch => $job_template->product->arch,
                distri => $job_template->product->distri,
                flavor => $job_template->product->flavor,
                version => $job_template->product->version,
                'settings[TEST]' => '1'
            })->status_is(200, 'Product settings are not locked');
        diag explain $t->tx->res->body if !$t->success;
        $t->delete_ok('/api/v1/products/' . $job_template->product_id)->json_is(
            '' =>
              {error_status => 400, error => 'Groups foo, opensuse, test must be updated through the YAML template'},
            'Attempt to delete product used in group was blocked'
        );
        $t->post_ok('/api/v1/machines/' . $job_template->machine_id, form => {name => 'deadbeef', backend => 'kde/usb'})
          ->json_is(
            '' =>
              {error_status => 400, error => 'Groups foo, opensuse, test must be updated through the YAML template'},
            'Attempt to rename machine used in group was blocked'
          );
        $t->post_ok('/api/v1/machines/' . $job_template->machine_id,
            form => {name => $job_template->machine->name, backend => 'kde/usb', 'settings[TEST]' => '1'})
          ->status_is(200, 'Machine settings are not locked');
        diag explain $t->tx->res->body if !$t->success;
        $t->delete_ok('/api/v1/machines/' . $job_template->machine_id)->json_is(
            '' =>
              {error_status => 400, error => 'Groups foo, opensuse, test must be updated through the YAML template'},
            'Attempt to delete machine used in group was blocked'
        );
        $t->post_ok('/api/v1/test_suites/' . $job_template->test_suite_id, form => {name => 'deadbeef'})->json_is(
            '' => {error_status => 400, error => 'Group opensuse must be updated through the YAML template'},
            'Attempt to rename test suite used in group was blocked'
        );
        $t->post_ok('/api/v1/test_suites/' . $job_template->test_suite_id,
            form => {name => $job_template->test_suite->name, description => 'Lorem ipsum'})
          ->status_is(200, 'Description is not locked');
        diag explain $t->tx->res->body if !$t->success;
        $t->post_ok('/api/v1/test_suites/' . $job_template->test_suite_id,
            form => {name => $job_template->test_suite->name, description => 'Lorem ipsum', 'settings[TEST]' => '1'})
          ->status_is(200, 'Test suite settings are not locked');
        diag explain $t->tx->res->body if !$t->success;
        $t->delete_ok('/api/v1/test_suites/' . $job_template->test_suite_id)->json_is(
            '' => {error_status => 400, error => 'Group opensuse must be updated through the YAML template'},
            'Attempt to delete test suite used in group was blocked'
        );
    }
};

# Test suites which are part of a group managed in YAML can't be modified manually
ok($opensuse->template, 'Group ' . $opensuse->name . ' is managed in YAML');
# set priority for particular test suite
$t->post_ok(
    '/api/v1/job_templates',
    form => {
        group_id => $opensuse->id,
        test_suite_id => 1002,
        prio => 15,
        prio_only => 1,
    })->status_is(400, 'Attempt to modify priority was blocked');

$t->delete_ok("/api/v1/job_templates/$job_template_id1")->status_is(400, 'Attempt to delete was blocked');
$opensuse->update({template => undef});

$t->delete_ok("/api/v1/job_templates/$job_template_id1")->status_is(200);
$t->delete_ok("/api/v1/job_templates/$job_template_id1")->status_is(404);

$t->delete_ok("/api/v1/job_templates/$job_template_id2")->status_is(200);
$t->delete_ok("/api/v1/job_templates/$job_template_id2")->status_is(404);
is_deeply(
    OpenQA::Test::Case::find_most_recent_event($t->app->schema, 'jobtemplate_delete'),
    {id => "$job_template_id2"},
    'Delete was logged correctly'
);

# switch to operator (default client) and try some modifications
client($t);
$t->post_ok(
    '/api/v1/job_templates',
    form => {
        group_id => 1001,
        machine_id => 1001,
        test_suite_id => 1002,
        product_id => 1,
        prio => 30
    })->status_is(403);
$t->delete_ok("/api/v1/job_templates/$job_template_id1")->status_is(403);

done_testing();
