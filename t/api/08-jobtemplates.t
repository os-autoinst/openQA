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

BEGIN {
    unshift @INC, 'lib';
}

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
                'settings' => {
                    'ADVANCED' => '1',
                    'DESKTOP'  => 'advanced_kde'
                },
                'id' => 10,
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
ok($job_template_id1, 'got ID (1)');

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
ok($job_template_id2, 'got ID (2)');
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
my $yaml = {};
is_deeply($t->app->validate_yaml($yaml, 1), [], 'Empty YAML is fine')
  or diag explain YAML::XS::Dump($yaml);
$yaml->{groupname}{architectures}{'x86_64'}{opensuse} = ['spam', 'eggs'];
is_deeply($t->app->validate_yaml($yaml, 1), ["/groupname/products: Missing property."], 'No products defined')
  or diag explain YAML::XS::Dump($yaml);
$yaml->{groupname}{products}{'opensuse'} = {};
is_deeply(
    @{$t->app->validate_yaml($yaml, 1)}[0],
    '/groupname/products/opensuse/distribution: Missing property.',
    'No distri specified'
) or diag explain YAML::XS::Dump($yaml);
$yaml->{groupname}{products}{'opensuse'}{distribution} = 'sle';
is_deeply(
    @{$t->app->validate_yaml($yaml, 1)}[0],
    '/groupname/products/opensuse/flavor: Missing property.',
    'No flavor specified'
) or diag explain YAML::XS::Dump($yaml);
$yaml->{groupname}{products}{'opensuse'}{flavor} = 'DVD';
is_deeply(
    $t->app->validate_yaml($yaml, 1),
    ['/groupname/products/opensuse/version: Missing property.'],
    'No version specified'
) or diag explain YAML::XS::Dump($yaml);
$yaml->{groupname}{products}{'opensuse'}{version} = '42.1';
# Add non-trivial test suites to exercise the validation
$yaml->{groupname}{architectures}{'x86_64'}{opensuse} = [
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
# Make 40 our default priority, which matters when we look at the "defaults" key later
$job_groups->find({name => 'opensuse'})->update({default_priority => 40});
# Get all groups
$t->get_ok("/api/v1/experimental/job_templates_scheduling")->status_is(200);
$yaml = YAML::XS::Load($t->tx->res->body);
is_deeply($t->app->validate_yaml($yaml, 1), [], 'YAML of all groups is valid');
is($yaml->{opensuse}{products}{'opensuse-13.1-DVD-i586'}{version}, '13.1', 'Version of opensuse group')
  || diag explain $t->tx->res->body;
# Get one group with defined architectures, products and defaults
$t->get_ok("/api/v1/experimental/job_templates_scheduling/1001")->status_is(200);
$yaml = YAML::XS::Load($t->tx->res->body);
is_deeply($t->app->validate_yaml($yaml, 1), [], 'YAML of single group is valid');
is_deeply(
    $yaml,
    {
        opensuse => {
            architectures => {
                i586 => {
                    'opensuse-13.1-DVD-i586' => [
                        'textmode',
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
                        'kde',
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
                        'client1',
                        'server',
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
                        'client2',
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
                    distribution => 'opensuse',
                    flavor       => 'DVD',
                    version      => '13.1',
                },
            },
        },
    },
    'YAML for opensuse group'
) || diag explain $t->tx->res->body;

# Add unicode characters to group name to see if the encoding is correct
$job_groups->find({name => 'opensuse'})->update({name => 'öpensüse'});
# Swap the group name in the expected YAML
$yaml->{'öpensüse'} = $yaml->{'opensuse'};
delete $yaml->{'opensuse'};
$t->get_ok("/api/v1/experimental/job_templates_scheduling/1001")->status_is(200)
  ->content_type_is('text/yaml;charset=UTF-8');
is_deeply(YAML::XS::Load($t->tx->res->body), $yaml, 'Test suite with unicode characters encoded correctly')
  || diag explain $t->tx->res->body;

# Remove unicode characters from the group name to simplify further testing
$job_groups->find({name => 'öpensüse'})->update({name => 'opensuse'});
# Swap the group name in the expected YAML
$yaml->{'opensuse'} = $yaml->{'öpensüse'};
delete $yaml->{'öpensüse'};

my $template = {opensuse => {}};
# Attempting to modify group with erroneous YAML should fail
$t->post_ok(
    '/api/v1/experimental/job_templates_scheduling',
    form => {
        template => YAML::XS::Dump($template)}
)->status_is(400)->json_is(
    '' => {
        error_status => 400,
        error        => [
            {path => '/opensuse/architectures', message => 'Missing property.'},
            {path => '/opensuse/products',      message => 'Missing property.'},
        ],
    },
    'posting invalid YAML template results in error'
);

subtest 'Create and modify groups with YAML' => sub {
    # Create group and job templates based on YAML template
    $yaml = {
        foo => {
            architectures => {
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
                    distribution => 'opensuse',
                    flavor       => 'DVD',
                    version      => '13.1',
                },
            },
        },
    };
    $t->post_ok(
        '/api/v1/experimental/job_templates_scheduling',
        form => {
            template => YAML::XS::Dump($yaml)}
    )->status_is(400, 'Post rejected because testsuite does not exist')->json_is(
        '' => {
            error        => ['Testsuite \'foobar\' is invalid'],
            error_status => 400,
            id           => 1003
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
        '/api/v1/experimental/job_templates_scheduling',
        form => {
            preview  => 1,
            template => YAML::XS::Dump($yaml),
        });
    $t->status_is(200, 'Posting preview successful');
    my $job_group_id3 = $t->tx->res->json->{id};
    $t->get_ok("/api/v1/experimental/job_templates_scheduling/$job_group_id3");
    is_deeply(YAML::XS::Load($t->tx->res->body), {}, 'No job group and templates added to the database')
      || diag explain $t->tx->res->body;
    is($audit_events->count, $audit_event_count, 'no audit event emitted in preview mode');

    $t->post_ok('/api/v1/experimental/job_templates_scheduling', form => {template => YAML::XS::Dump($yaml)});
    $t->status_is(200, 'Changes applied to the database');
    if (!$t->success) {
        return undef;
    }
    $job_group_id3 = $t->tx->res->json->{id};
    $t->get_ok("/api/v1/experimental/job_templates_scheduling/$job_group_id3");
    # Prepare expected result
    splice @{$yaml->{foo}{architectures}{i586}{'opensuse-13.1-DVD-i586'}}, 0, 2;
    unshift @{$yaml->{foo}{architectures}{i586}{'opensuse-13.1-DVD-i586'}}, {'spam'   => {priority => 40}};
    unshift @{$yaml->{foo}{architectures}{i586}{'opensuse-13.1-DVD-i586'}}, {'foobar' => {priority => 40}};
    # Use per-arch default priority which deviates from the group default_priority
    $yaml->{foo}{defaults}{i586}{'priority'} = 50;
    is_deeply(YAML::XS::Load($t->tx->res->body), $yaml, 'Added job template reflected in the database')
      || diag explain $t->tx->res->body;

    subtest 'Modify test attributes in group according to YAML template' => sub {
        my %foobar_definition = (
            priority => 11,
            machine  => '32bit',
            settings => {
                BAR => 'updated value',
                NEW => 'new setting',
            },
        );
        $yaml->{foo}{architectures}{i586}{'opensuse-13.1-DVD-i586'} = [{foobar => \%foobar_definition}, 'spam', 'eggs'];
        # Use per-arch default priority which deviates from the group default_priority
        $yaml->{foo}{defaults}{i586}{'priority'} = 70;
        $t->post_ok(
            '/api/v1/experimental/job_templates_scheduling',
            form => {
                template => YAML::XS::Dump($yaml)}
        )->status_is(200)->json_is(
            '' => {
                id => $job_group_id3,
            },
            'Test suite was updated'
        );
        # Prepare expected result
        $yaml->{foo}{architectures}{i586}{'opensuse-13.1-DVD-i586'}
          = [{foobar => \%foobar_definition}, {spam => {priority => 70}}, {eggs => {priority => 70}}];
        # Result *should* in fact be 70, but we get the default_priority
        $yaml->{foo}{defaults}{i586}{'priority'} = 50;
        $t->get_ok("/api/v1/experimental/job_templates_scheduling/$job_group_id3");
        is_deeply(YAML::XS::Load($t->tx->res->body), $yaml, 'Modified test suite should be reflected in the database')
          || diag explain $t->tx->res->body;
    };

    subtest 'Post unmodified job template' => sub {
        $t->post_ok(
            '/api/v1/experimental/job_templates_scheduling',
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
        $yaml->{foo}{architectures}{i586}{'opensuse-13.1-DVD-i586'}
          = [{foobar => {priority => 11, machine => '31bit'}}];
        $t->post_ok(
            '/api/v1/experimental/job_templates_scheduling',
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

        $yaml->{foo}{architectures}{i586}{'opensuse-13.1-DVD-i586'} = ['foo'];
        $yaml->{foo}{defaults}{i586}{'machine'}                     = '66bit';
        $t->post_ok(
            '/api/v1/experimental/job_templates_scheduling',
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

        $yaml->{foo}{defaults}{i586}{'machine'}                          = '64bit';
        $yaml->{foo}{products}{'opensuse-13.1-DVD-i586'}{'distribution'} = 'geeko';
        $t->post_ok(
            '/api/v1/experimental/job_templates_scheduling',
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
    # Create group based on YAML with references
    $yaml = YAML::XS::Load('
    test:
      architectures:
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
          distribution: opensuse
          flavor: DVD
          version: 13.1
        opensuse-13.1-DVD-ppc64:
          *opensuse13
        sle-12-SP1-Server-DVD-Updates-x86_64:
          distribution: sle
          flavor: Server-DVD-Updates
          version: 12-SP1
    ');
    $t->post_ok('/api/v1/experimental/job_templates_scheduling', form => {template => YAML::XS::Dump($yaml)});
    $t->status_is(200, 'New group with references was added to the database');
    if (!$t->success) {
        diag explain $t->tx->res->json;
        return undef;
    }

    my $job_group_id4 = $t->tx->res->json->{id};
    $t->get_ok("/api/v1/experimental/job_templates_scheduling/$job_group_id4");
    # Prepare expected result
    $yaml->{test}{architectures}{ppc64}{'opensuse-13.1-DVD-ppc64'} = [qw(spam eggs)];
    is_deeply(YAML::XS::Load($t->tx->res->body),
        $yaml, 'Added group with references should be reflected in the database')
      || diag explain $t->tx->res->body;
};

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
