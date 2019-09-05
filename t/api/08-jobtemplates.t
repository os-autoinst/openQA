# Copyright (C) 2014-2019 SUSE Linux Products GmbH
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

use Mojo::Base -strict;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;
use OpenQA::Client;
use OpenQA::WebAPI::Controller::API::V1::JobTemplate;
use Mojo::IOLoop;

OpenQA::Test::Case->new->init_data;

my $t = Test::Mojo->new('OpenQA::WebAPI');

# XXX: Test::Mojo loses it's app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(OpenQA::Client->new(apikey => 'ARTHURKEY01', apisecret => 'EXCALIBUR')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

my $schema        = $app->schema;
my $job_groups    = $schema->resultset('JobGroups');
my $job_templates = $schema->resultset('JobTemplates');
my $test_suites   = $schema->resultset('TestSuites');
my $audit_events  = $schema->resultset('AuditEvents');

$t->get_ok('/api/v1/job_templates')->status_is(200);
is_deeply(
    $t->tx->res->json,
    {
        'JobTemplates' => [
            {
                'group_name' => 'opensuse',
                'id'         => 1,
                'test_suite' => {
                    'name' => 'textmode',
                    'id'   => 1001
                },
                'prio'    => 40,
                'machine' => {
                    'name' => '32bit',
                    'id'   => 1001
                },
                'product' => {
                    'distri'  => 'opensuse',
                    'version' => '13.1',
                    'flavor'  => 'DVD',
                    'arch'    => 'i586',
                    'group'   => 'opensuse-13.1-DVD',
                    'id'      => 1
                }
            },
            {
                'product' => {
                    'distri'  => 'opensuse',
                    'version' => '13.1',
                    'flavor'  => 'DVD',
                    'group'   => 'opensuse-13.1-DVD',
                    'arch'    => 'i586',
                    'id'      => 1
                },
                'machine' => {
                    'name' => '64bit',
                    'id'   => 1002
                },
                'prio'       => 40,
                'id'         => 2,
                'test_suite' => {
                    'id'   => 1001,
                    'name' => 'textmode'
                },
                'group_name' => 'opensuse'
            },
            {
                'test_suite' => {
                    'name' => 'kde',
                    'id'   => 1002
                },
                'id'         => 3,
                'group_name' => 'opensuse',
                'machine'    => {
                    'name' => '64bit',
                    'id'   => 1002
                },
                'prio'    => 40,
                'product' => {
                    'version' => '13.1',
                    'flavor'  => 'DVD',
                    'distri'  => 'opensuse',
                    'id'      => 1,
                    'group'   => 'opensuse-13.1-DVD',
                    'arch'    => 'i586'
                }
            },
            {
                'machine' => {
                    'name' => '32bit',
                    'id'   => 1001
                },
                'prio'    => 40,
                'product' => {
                    'id'      => 1,
                    'arch'    => 'i586',
                    'group'   => 'opensuse-13.1-DVD',
                    'flavor'  => 'DVD',
                    'version' => '13.1',
                    'distri'  => 'opensuse'
                },
                'id'         => 4,
                'test_suite' => {
                    'id'   => 1014,
                    'name' => 'client1'
                },
                'group_name' => 'opensuse'
            },
            {
                'test_suite' => {
                    'name' => 'client2',
                    'id'   => 1016
                },
                'id'         => 5,
                'group_name' => 'opensuse',
                'prio'       => 40,
                'machine'    => {
                    'name' => '32bit',
                    'id'   => 1001
                },
                'product' => {
                    'distri'  => 'opensuse',
                    'flavor'  => 'DVD',
                    'version' => '13.1',
                    'arch'    => 'i586',
                    'group'   => 'opensuse-13.1-DVD',
                    'id'      => 1
                }
            },
            {
                'machine' => {
                    'name' => '32bit',
                    'id'   => 1001
                },
                'prio'    => 40,
                'product' => {
                    'distri'  => 'opensuse',
                    'flavor'  => 'DVD',
                    'version' => '13.1',
                    'group'   => 'opensuse-13.1-DVD',
                    'arch'    => 'i586',
                    'id'      => 1
                },
                'test_suite' => {
                    'id'   => 1015,
                    'name' => 'server'
                },
                'id'         => 6,
                'group_name' => 'opensuse'
            },
            {
                'group_name' => 'opensuse',
                'test_suite' => {
                    'name' => 'client1',
                    'id'   => 1014
                },
                'id'      => 7,
                'prio'    => 40,
                'machine' => {
                    'name' => '64bit',
                    'id'   => 1002
                },
                'product' => {
                    'version' => '13.1',
                    'flavor'  => 'DVD',
                    'distri'  => 'opensuse',
                    'id'      => 1,
                    'group'   => 'opensuse-13.1-DVD',
                    'arch'    => 'i586'
                }
            },
            {
                'group_name' => 'opensuse',
                'test_suite' => {
                    'name' => 'client2',
                    'id'   => 1016
                },
                'id'      => 8,
                'product' => {
                    'id'      => 1,
                    'group'   => 'opensuse-13.1-DVD',
                    'arch'    => 'i586',
                    'version' => '13.1',
                    'flavor'  => 'DVD',
                    'distri'  => 'opensuse'
                },
                'prio'    => 40,
                'machine' => {
                    'name' => '64bit',
                    'id'   => 1002
                }
            },
            {
                'group_name' => 'opensuse',
                'id'         => 9,
                'test_suite' => {
                    'name' => 'server',
                    'id'   => 1015
                },
                'prio'    => 40,
                'machine' => {
                    'name' => '64bit',
                    'id'   => 1002
                },
                'product' => {
                    'arch'    => 'i586',
                    'group'   => 'opensuse-13.1-DVD',
                    'id'      => 1,
                    'distri'  => 'opensuse',
                    'flavor'  => 'DVD',
                    'version' => '13.1'
                }
            },
            {
                'product' => {
                    'distri'  => 'opensuse',
                    'flavor'  => 'DVD',
                    'version' => '13.1',
                    'arch'    => 'i586',
                    'group'   => 'opensuse-13.1-DVD',
                    'id'      => 1
                },
                'prio'    => 40,
                'machine' => {
                    'id'   => 1002,
                    'name' => '64bit'
                },
                'group_name' => 'opensuse',
                'test_suite' => {
                    'name' => 'advanced_kde',
                    'id'   => 1017
                },
                'settings' => [{key => 'ADVANCED', value => '1'}, {key => 'DESKTOP', value => 'advanced_kde'},],
                'id'       => 10,
            }]
    },
    "Initial job templates"
) || diag explain $t->tx->res->json;


$t->post_ok(
    '/api/v1/job_templates',
    form => {
        group_id      => 1001,
        machine_id    => 1001,
        test_suite_id => 1002,
        product_id    => 1,
        prio          => 30
    })->status_is(200);
my $job_template_id1 = $t->tx->res->json->{id};
ok($job_template_id1, "Created job template ($job_template_id1)");

$t->post_ok(
    '/api/v1/job_templates',
    form => {
        group_name      => 'opensuse',
        machine_name    => '64bit',
        test_suite_name => 'RAID0',
        arch            => 'i586',
        distri          => 'opensuse',
        flavor          => 'DVD',
        version         => '13.1',
        prio            => 20
    })->status_is(200);
my $job_template_id2 = $t->tx->res->json->{id};
ok($job_template_id2, "Created job template ($job_template_id2)");
is_deeply(
    OpenQA::Test::Case::find_most_recent_event($schema, 'jobtemplate_create'),
    {id => $job_template_id2},
    'Create was logged correctly'
);

$t->get_ok("/api/v1/job_templates/$job_template_id1")->status_is(200);
is_deeply(
    $t->tx->res->json,
    {
        'JobTemplates' => [
            {
                'id'         => $job_template_id1,
                'group_name' => 'opensuse',
                'machine'    => {
                    'id'   => 1001,
                    'name' => '32bit'
                },
                'prio'    => 30,
                'product' => {
                    'arch'    => 'i586',
                    'distri'  => 'opensuse',
                    'flavor'  => 'DVD',
                    'id'      => 1,
                    'version' => '13.1',
                    'group'   => 'opensuse-13.1-DVD',
                },
                'test_suite' => {
                    'id'   => 1002,
                    'name' => 'kde'
                }}]

    },
    "Initial job templates"
) || diag explain $t->tx->res->json;

$t->get_ok("/api/v1/job_templates/$job_template_id2")->status_is(200);
is_deeply(
    $t->tx->res->json,
    {
        'JobTemplates' => [
            {
                'group_name' => 'opensuse',
                'prio'       => 20,
                'test_suite' => {
                    'id'   => 1013,
                    'name' => 'RAID0'
                },
                'machine' => {
                    'id'   => 1002,
                    'name' => '64bit'
                },
                'product' => {
                    'arch'    => 'i586',
                    'version' => '13.1',
                    'id'      => 1,
                    'group'   => 'opensuse-13.1-DVD',
                    'distri'  => 'opensuse',
                    'flavor'  => 'DVD'
                },
                'id' => $job_template_id2
            }]
    },
    "Initial job templates"
) || diag explain $t->tx->res->json;

# search by name
$t->get_ok(
    "/api/v1/job_templates",
    form => {
        machine_name    => '64bit',
        test_suite_name => 'RAID0',
        'arch'          => 'i586',
        'distri'        => 'opensuse',
        'flavor'        => 'DVD',
        'version'       => '13.1'
    })->status_is(200);
is_deeply(
    $t->tx->res->json,
    {
        'JobTemplates' => [
            {
                'id'         => $job_template_id2,
                'group_name' => 'opensuse',
                'prio'       => 20,
                'machine'    => {
                    'id'   => 1002,
                    'name' => '64bit'
                },
                'product' => {
                    'arch'    => 'i586',
                    'distri'  => 'opensuse',
                    'flavor'  => 'DVD',
                    'id'      => 1,
                    'version' => '13.1',
                    'group'   => 'opensuse-13.1-DVD'
                },
                'test_suite' => {
                    'id'   => 1013,
                    'name' => 'RAID0'
                }}]
    },
    "Initial job templates"
) || diag explain $t->tx->res->json;

# search all job templates with testsuite 'kde'
$t->get_ok("/api/v1/job_templates", form => {test_suite_name => 'kde'})->status_is(200);
is_deeply(
    $t->tx->res->json,
    {
        'JobTemplates' => [
            {
                'id'         => 3,
                'prio'       => 40,
                'group_name' => 'opensuse',
                'machine'    => {
                    'id'   => 1002,
                    'name' => '64bit'
                },
                'product' => {
                    'arch'    => 'i586',
                    'distri'  => 'opensuse',
                    'flavor'  => 'DVD',
                    'id'      => 1,
                    'version' => '13.1',
                    'group'   => 'opensuse-13.1-DVD',
                },
                'test_suite' => {
                    'id'   => 1002,
                    'name' => 'kde'
                }
            },
            {
                'id'         => $job_template_id1,
                'group_name' => 'opensuse',
                'prio'       => 30,
                'machine'    => {
                    'id'   => 1001,
                    'name' => '32bit'
                },
                'product' => {
                    'arch'    => 'i586',
                    'distri'  => 'opensuse',
                    'flavor'  => 'DVD',
                    'id'      => 1,
                    'version' => '13.1',
                    'group'   => 'opensuse-13.1-DVD',
                },
                'test_suite' => {
                    'id'   => 1002,
                    'name' => 'kde'
                }}]
    },
    "Initial job templates"
) || diag explain $t->tx->res->json;

# need to specify 'prio_only' for setting prio of job tempaltes by group and testsuite
$t->post_ok(
    '/api/v1/job_templates',
    form => {
        group_id      => 1001,
        test_suite_id => 1002,
        prio          => 15,
    }
)->status_is(400)->json_is(
    '' => {
        error_status => 400,
        error        => 'wrong parameter: group_name machine_name test_suite_name arch distri flavor version'
    },
    'setting prio for group/testsuite requires prio-only parameter'
);
is($job_templates->search({prio => 15})->count, 0, 'no rows affected');

# set priority for particular test suite
$t->post_ok(
    '/api/v1/job_templates',
    form => {
        group_id      => 1001,
        test_suite_id => 1002,
        prio          => 15,
        prio_only     => 1,
    }
)->status_is(200)->json_is(
    '' => {
        affected_rows => 2,
    },
    'two rows affected'
);
is($job_templates->search({prio => 15})->count, 2, 'two rows have now prio 15');
is_deeply(
    OpenQA::Test::Case::find_most_recent_event($app->schema, 'jobtemplate_create'),
    {affected_rows => 2},
    'Create was logged correctly'
);

# set priority to undef for inheriting from job group
$t->post_ok(
    '/api/v1/job_templates',
    form => {
        group_id      => 1001,
        test_suite_id => 1002,
        prio          => 'inherit',
        prio_only     => 1,
    }
)->status_is(200)->json_is(
    '' => {
        affected_rows => 2,
    },
    'two rows affected'
);
is($job_templates->search({prio => undef})->count, 2, 'two rows have now prio undef');

# priority is validated
$t->post_ok(
    '/api/v1/job_templates',
    form => {
        group_id      => 1001,
        test_suite_id => 1002,
        prio          => '-5',
        prio_only     => 1,
    }
)->status_is(400)->json_is(
    '' => {
        error_status => 400,
        error        => 'wrong parameter: prio'
    },
    'setting invalid priority results in error'
);
is($job_templates->search({prio => -5})->count, 0, 'no rows affected');

# test the YAML export
# Test validation
my $product = 'open-*.SUSE1';
my $yaml    = {};
is_deeply(scalar @{$t->app->validate_yaml($yaml, 1)}, 2, 'Empty YAML is an error')
  or diag explain YAML::XS::Dump($yaml);
$yaml->{scenarios}{'x86_64'}{$product} = ['spam', 'eggs'];
is_deeply($t->app->validate_yaml($yaml, 1), ["/products: Missing property."], 'No products defined')
  or diag explain YAML::XS::Dump($yaml);
$yaml->{products}{$product} = {};
is_deeply(@{$t->app->validate_yaml($yaml, 1)}[0], "/products/$product/distri: Missing property.", 'No distri specified')
  or diag explain YAML::XS::Dump($yaml);
$yaml->{products}{$product}{distri} = 'sle';
is_deeply(@{$t->app->validate_yaml($yaml, 1)}[0], "/products/$product/flavor: Missing property.", 'No flavor specified')
  or diag explain YAML::XS::Dump($yaml);
$yaml->{products}{$product}{flavor} = 'DVD';
is_deeply($t->app->validate_yaml($yaml, 1), ["/products/$product/version: Missing property."], 'No version specified')
  or diag explain YAML::XS::Dump($yaml);
$yaml->{products}{$product}{distribution} = 'sle';
is_deeply(
    @{$t->app->validate_yaml($yaml, 1)}[0],
    "/products/$product: Properties not allowed: distribution.",
    'Invalid product property specified'
) or diag explain YAML::XS::Dump($yaml);
delete $yaml->{products}{$product}{distribution};
$yaml->{products}{$product}{version} = '42.1';
# Add non-trivial test suites to exercise the validation
$yaml->{scenarios}{'x86_64'}{$product} = [
    'spam',
    "eg-G_S +133t*\t",
    {
        'foo'               => {},
        "b-A_RRRR +133t*\t" => {
            machine  => 'x86_64',
            priority => 33,
        },
    }];
is_deeply($t->app->validate_yaml($yaml, 1), [], 'YAML valid as expected')
  or diag explain YAML::XS::Dump($yaml);
my $opensuse = $job_groups->find({name => 'opensuse'});
# Make 40 our default priority, which matters when we look at the "defaults" key later
$opensuse->update({default_priority => 40});
# Get all groups
$t->get_ok("/api/v1/experimental/job_templates_scheduling")->status_is(200);
$yaml = YAML::XS::Load($t->tx->res->body);
is_deeply(['opensuse', 'opensuse test'], [sort keys %$yaml], 'YAML of all groups contains names')
  || diag explain $t->tx->res->body;
# Get one group with defined scenarios, products and defaults
$t->get_ok('/api/v1/experimental/job_templates_scheduling/' . $opensuse->id)->status_is(200);
# A document start marker "---" shouldn't be present by default
$yaml = $t->tx->res->body =~ s/---\n//r;
is($t->tx->res->body, $yaml, 'No document start marker by default');
$yaml = YAML::XS::Load($t->tx->res->body);
is_deeply($t->app->validate_yaml($yaml, 1), [], 'YAML of single group is valid');
is_deeply(
    $yaml,
    {
        scenarios => {
            i586 => {
                'opensuse-13.1-DVD-i586' => [
                    {
                        textmode => {
                            machine => '64bit',
                        }
                    },
                    {
                        textmode => {
                            machine => '32bit',
                        }
                    },
                    {
                        kde => {
                            machine => '32bit',
                        }
                    },
                    {
                        kde => {
                            machine => '64bit',
                        }
                    },
                    {
                        RAID0 => {
                            priority => 20,
                        }
                    },
                    {
                        client1 => {
                            machine => '32bit',
                        }
                    },
                    {
                        client1 => {
                            machine => '64bit',
                        }
                    },
                    {
                        server => {
                            machine => '64bit',
                        }
                    },
                    {
                        server => {
                            machine => '32bit',
                        }
                    },
                    {
                        client2 => {
                            machine => '32bit',
                        }
                    },
                    {
                        client2 => {
                            machine => '64bit',
                        }
                    },
                    {
                        advanced_kde => {
                            settings => {
                                DESKTOP  => 'advanced_kde',
                                ADVANCED => '1',
                            }}
                    },
                ],
            },
        },
        defaults => {
            i586 => {
                machine  => '64bit',
                priority => 40,
            },
        },
        products => {
            'opensuse-13.1-DVD-i586' => {
                distri  => 'opensuse',
                flavor  => 'DVD',
                version => '13.1',
            },
        },
    },
    'YAML for opensuse group'
) || diag explain $t->tx->res->body;

$t->get_ok('/api/v1/experimental/job_templates_scheduling/' . $opensuse->id)->status_is(200)
  ->content_type_is('text/yaml;charset=UTF-8');
is_deeply(YAML::XS::Load($t->tx->res->body), $yaml, 'Test suite with unicode characters encoded correctly')
  || diag explain $t->tx->res->body;

subtest 'Migration' => sub {
    # Legacy group was created with no YAML
    is($opensuse->template, undef, 'No YAML stored in the database');

    # After posting YAML the exact template is stored
    $yaml = YAML::XS::Dump($yaml);
    $t->post_ok('/api/v1/experimental/job_templates_scheduling/' . $opensuse->id, form => {template => $yaml})
      ->status_is(200, 'YAML added to the database');
    if (!$t->success) {
        return undef;
    }
    $opensuse->discard_changes;
    is($opensuse->template, $yaml, 'YAML stored in the database');
    $yaml = "# comments help readability\n$yaml# or in the end\n";
    $t->post_ok('/api/v1/experimental/job_templates_scheduling/' . $opensuse->id, form => {template => $yaml})
      ->status_is(200, 'YAML with comments posted');
    $t->get_ok('/api/v1/experimental/job_templates_scheduling/' . $opensuse->id);
    is($t->tx->res->body, $yaml, 'YAML with comments preserved in the database');
};

subtest 'Conflicts' => sub {
    $t->post_ok(
        '/api/v1/experimental/job_templates_scheduling/' . $opensuse->id,
        form => {
            reference => 'some invalid yaml',
            template  => $yaml,
        }
    )->json_is(
        '' => {
            error_status => 400,
            error        => ['Template was modified',],
            id           => $opensuse->id,
            template     => $yaml,
        },
        'posting with wrong reference fails'
    );

    $t->post_ok(
        '/api/v1/experimental/job_templates_scheduling/' . $opensuse->id,
        form => {
            reference => $yaml,
            template  => $yaml,
        })->status_is(200, 'posting with correct reference succeeds');
};

my $template = {};
# Attempting to modify group with erroneous YAML should fail
$t->post_ok(
    '/api/v1/experimental/job_templates_scheduling/' . $opensuse->id,
    form => {
        template => YAML::XS::Dump($template)}
)->status_is(400)->json_is(
    '' => {
        error_status => 400,
        error        => [
            {path => '/products',  message => 'Missing property.'},
            {path => '/scenarios', message => 'Missing property.'},
        ],
    },
    'posting invalid YAML template results in error'
);

subtest 'Create and modify groups with YAML' => sub {
    my $job_group_id3 = $job_groups->create({name => 'foo'})->id;
    ok($job_group_id3, "Created group foo ($job_group_id3)");

    # Create group and job templates based on YAML template
    $yaml = {
        scenarios => {
            i586 => {
                'opensuse-13.1-DVD-i586' => [
                    'foobar',    # Test names shouldn't conflict across groups
                    'spam',
                    {
                        eggs => {
                            machine  => '32bit',
                            priority => 20,
                            settings => {
                                FOO => 'removed later',
                                BAR => 'updated later',
                            },
                        },
                    },
                ],
            },
        },
        defaults => {
            i586 => {
                machine  => '64bit',
                priority => 40,
            },
        },
        products => {
            'opensuse-13.1-DVD-i586' => {
                distri  => 'opensuse',
                flavor  => 'DVD',
                version => '13.1',
            },
        },
    };
    $t->post_ok(
        "/api/v1/experimental/job_templates_scheduling/$job_group_id3",
        form => {
            template => YAML::XS::Dump($yaml)}
    )->status_is(400, 'Post rejected because testsuite does not exist')->json_is(
        '' => {
            error        => ['Testsuite \'foobar\' is invalid'],
            error_status => 400,
            id           => $job_group_id3
        },
        'Invalid testsuite'
    );

    # Add required testsuites
    for my $test_suite_name (qw(foobar spam eggs)) {
        $test_suites->create({name => $test_suite_name});
    }

    # Assert that nothing changes in preview mode
    my $audit_event_count = $audit_events->count;
    $t->post_ok(
        "/api/v1/experimental/job_templates_scheduling/$job_group_id3",
        form => {
            preview  => 1,
            template => YAML::XS::Dump($yaml),
        });
    $t->status_is(200, 'Posting preview successful');
    $t->get_ok("/api/v1/experimental/job_templates_scheduling/$job_group_id3");
    is_deeply(
        YAML::XS::Load($t->tx->res->body),
        {scenarios => {}, products => {}},
        'No job group and templates added to the database'
    ) || diag explain $t->tx->res->body;
    is($audit_events->count, $audit_event_count, 'no audit event emitted in preview mode');

    $t->post_ok("/api/v1/experimental/job_templates_scheduling/$job_group_id3",
        form => {template => YAML::XS::Dump($yaml)});
    $t->status_is(200, 'Changes applied to the database');
    if (!$t->success) {
        return undef;
    }
    $t->get_ok("/api/v1/experimental/job_templates_scheduling/$job_group_id3");
    is_deeply(YAML::XS::Load($t->tx->res->body), $yaml, 'Added job template reflected in the database')
      || diag explain $t->tx->res->body;

    subtest 'Modify test attributes in group according to YAML template' => sub {
        $yaml->{defaults}{i586}{settings} = {BAR => 'unused default', FOO => 'default'};
        my %foobar_definition = (
            priority => 11,
            machine  => '32bit',
            settings => {
                BAR => 'updated value',
                NEW => 'new setting',
            },
        );
        $yaml->{scenarios}{i586}{'opensuse-13.1-DVD-i586'} = [{foobar => \%foobar_definition}, 'spam', 'eggs'];
        $t->post_ok(
            "/api/v1/experimental/job_templates_scheduling/$job_group_id3",
            form => {
                template => YAML::XS::Dump($yaml)})->status_is(200, 'Test suite was updated');
        my $job_template = $job_templates->find({prio => 11});
        is($job_template->machine_id, 1001, 'Updated machine reflected in the database');
        is_deeply(
            $job_template->settings_hash,
            {FOO => 'default', BAR => 'updated value', NEW => 'new setting'},
            'Modified attributes reflected in the database'
        );
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
            "/api/v1/experimental/job_templates_scheduling/$job_group_id3",
            form => {
                template => YAML::XS::Dump($yaml)}
        )->status_is(400, 'Post rejected because scenarios are ambiguous')->json_is(
            '' => {
                error => [
                        'Job template name \'foobar\' is defined more than once. '
                      . 'Use a unique name and specify \'testsuite\' to re-use test suites in multiple scenarios.'
                ],
                error_status => 400,
                id           => $job_group_id3
            },
            'Invalid testsuite'
        );

        # Specify testsuite to correctly disambiguate
        %foo_eggs = (
            testsuite => 'foobar',
            settings  => {
                FOO => 'eggs',
            },
        );
        $yaml->{scenarios}{i586}{'opensuse-13.1-DVD-i586'} = [{foobar => \%foo_spam}, {foobar_eggs => \%foo_eggs}];
        $yaml->{defaults}{i586}{'priority'}                = 16;
        $t->post_ok(
            "/api/v1/experimental/job_templates_scheduling/$job_group_id3",
            form => {
                template => YAML::XS::Dump($yaml)})->status_is(200);
        if (!$t->success) {
            diag explain $t->tx->res->json;
            return undef;
        }
        if (!is($job_templates->search({prio => 16})->count, 2, 'two distinct job templates')) {
            my $jt = $job_templates->search({prio => 16});
            while (my $j = $jt->next) {
                diag explain YAML::XS::Dump($j->to_hash);
            }
        }
    };

    subtest 'Post unmodified job template' => sub {
        $t->post_ok(
            "/api/v1/experimental/job_templates_scheduling/$job_group_id3",
            form => {
                template => YAML::XS::Dump($yaml)}
        )->status_is(200)->json_is(
            '' => {
                id => $job_group_id3
            },
            'No-op import of existing job template'
        );
        $t->get_ok("/api/v1/experimental/job_templates_scheduling/$job_group_id3");
        is_deeply(YAML::XS::Load($t->tx->res->body), $yaml, 'Unmodified group should not result in any changes')
          || diag explain $t->tx->res->body;
    };

    subtest 'Errors due to invalid properties' => sub {
        $yaml->{scenarios}{i586}{'opensuse-13.1-DVD-i586'}
          = [{foobar => {priority => 11, machine => '31bit'}}];
        $t->post_ok(
            "/api/v1/experimental/job_templates_scheduling/$job_group_id3",
            form => {
                template => YAML::XS::Dump($yaml)}
        )->status_is(400)->json_is(
            '' => {
                id           => $job_group_id3,
                error_status => 400,
                error        => ["Machine '31bit' is invalid"],
            },
            'Invalid machine in test suite'
        );

        $yaml->{scenarios}{i586}{'opensuse-13.1-DVD-i586'} = ['foo'];
        $yaml->{defaults}{i586}{'machine'}                 = '66bit';
        $t->post_ok(
            "/api/v1/experimental/job_templates_scheduling/$job_group_id3",
            form => {
                template => YAML::XS::Dump($yaml)}
        )->status_is(400)->json_is(
            '' => {
                id           => $job_group_id3,
                error_status => 400,
                error        => ["Machine '66bit' is invalid"],
            },
            'Invalid machine in defaults'
        );

        $yaml->{defaults}{i586}{'machine'}                    = '64bit';
        $yaml->{products}{'opensuse-13.1-DVD-i586'}{'distri'} = 'geeko';
        $t->post_ok(
            "/api/v1/experimental/job_templates_scheduling/$job_group_id3",
            form => {
                template => YAML::XS::Dump($yaml)}
        )->status_is(400)->json_is(
            '' => {
                id           => $job_group_id3,
                error_status => 400,
                error        => ["Product 'opensuse-13.1-DVD-i586' is invalid"],
            },
            'Invalid product'
        );
    };
};

subtest 'References' => sub {
    my $job_group_id4 = $job_groups->create({name => 'test'})->id;
    ok($job_group_id4, "Created group test ($job_group_id4)");
    # Create group based on YAML with references
    $yaml = YAML::XS::Load('
      scenarios:
        i586:
          opensuse-13.1-DVD-i586: &tests
          - spam
          - eggs
        ppc64:
          opensuse-13.1-DVD-ppc64:
            *tests
        x86_64:
          sle-12-SP1-Server-DVD-Updates-x86_64:
            *tests
      defaults:
        i586:
          machine: 32bit
          priority: 50
        ppc64:
          machine: 64bit
          priority: 50
        x86_64:
          machine: 64bit
          priority: 50
      products:
        opensuse-13.1-DVD-i586: &opensuse13
          distri: opensuse
          flavor: DVD
          version: 13.1
        opensuse-13.1-DVD-ppc64:
          *opensuse13
        sle-12-SP1-Server-DVD-Updates-x86_64:
          distri: sle
          flavor: Server-DVD-Updates
          version: 12-SP1
    ');
    $t->post_ok("/api/v1/experimental/job_templates_scheduling/$job_group_id4",
        form => {template => YAML::XS::Dump($yaml)});
    $t->status_is(200, 'New group with references was added to the database');
    if (!$t->success) {
        diag explain $t->tx->res->json;
        return undef;
    }

    $t->get_ok("/api/v1/experimental/job_templates_scheduling/$job_group_id4");
    # Prepare expected result
    $yaml->{scenarios}{ppc64}{'opensuse-13.1-DVD-ppc64'} = [qw(spam eggs)];
    is_deeply(YAML::XS::Load($t->tx->res->body),
        $yaml, 'Added group with references should be reflected in the database')
      || diag explain $t->tx->res->body;

    # Event reflects changes to the YAML
    $yaml->{scenarios}{ppc64}{'opensuse-13.1-DVD-ppc64'} = [qw(spam foobar)];
    $t->post_ok("/api/v1/experimental/job_templates_scheduling/$job_group_id4",
        form => {template => YAML::XS::Dump($yaml)})->status_is(200);
    if (!$t->success) {
        diag explain $t->tx->res->json;
        return undef;
    }

    is_deeply(
        OpenQA::Test::Case::find_most_recent_event($schema, 'jobtemplate_create'),
        {
            id      => $job_group_id4,
            changes => '@@ -23,7 +23,7 @@
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

# Test suites which are part of a group managed in YAML can't be modified manually
ok($opensuse->template, 'Group ' . $opensuse->name . ' is managed in YAML');
# set priority for particular test suite
$t->post_ok(
    '/api/v1/job_templates',
    form => {
        group_id      => $opensuse->id,
        test_suite_id => 1002,
        prio          => 15,
        prio_only     => 1,
    })->status_is(400, 'Attempt to modify priority was blocked');

$t->delete_ok("/api/v1/job_templates/$job_template_id1")->status_is(400, 'Attempt to delete was blocked');
$opensuse->update({template => undef});

$t->delete_ok("/api/v1/job_templates/$job_template_id1")->status_is(200);
$t->delete_ok("/api/v1/job_templates/$job_template_id1")->status_is(404);

$t->delete_ok("/api/v1/job_templates/$job_template_id2")->status_is(200);
$t->delete_ok("/api/v1/job_templates/$job_template_id2")->status_is(404);
is_deeply(
    OpenQA::Test::Case::find_most_recent_event($app->schema, 'jobtemplate_delete'),
    {id => "$job_template_id2"},
    'Delete was logged correctly'
);

# switch to operator (percival) and try some modifications
$app = $t->app;
$t->ua(
    OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);
$t->post_ok(
    '/api/v1/job_templates',
    form => {
        group_id      => 1001,
        machine_id    => 1001,
        test_suite_id => 1002,
        product_id    => 1,
        prio          => 30
    })->status_is(403);
$t->delete_ok("/api/v1/job_templates/$job_template_id1")->status_is(403);

done_testing();
