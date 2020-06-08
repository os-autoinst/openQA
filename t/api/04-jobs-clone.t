#!/usr/bin/env perl
# Copyright (C) 2014-2020
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
# with this program; if not, see <http://www.gnu.org/licenses/>.

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib";
use OpenQA::Script::CloneJob;
use OpenQA::Test::Database;
use Test::Mojo;
use Test::Warnings ':report_warnings';

OpenQA::Test::Database->new->create();

my $t = Test::Mojo->new('OpenQA::WebAPI');
# XXX: https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(
    OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

my $schema     = $t->app->schema;
my $products   = $schema->resultset("Products");
my $testsuites = $schema->resultset("TestSuites");
my $jobs       = $schema->resultset("Jobs");

my $minimalx = $jobs->find(99926);
my $clones   = $minimalx->duplicate();
my $clone    = $jobs->find($clones->{$minimalx->id}->{clone});

isnt($clone->id, $minimalx->id, "is not the same job");
is($clone->TEST,     "minimalx",  "but is the same test");
is($clone->priority, 56,          "with the same priority");
is($minimalx->state, "done",      "original test keeps its state");
is($clone->state,    "scheduled", "the new job is scheduled");

# Second attempt
ok($minimalx->can_be_duplicated, "looks cloneable");
is($minimalx->duplicate, undef, "cannot clone again");

# Reload minimalx from the database
$minimalx->discard_changes;
is($minimalx->clone_id,  $clone->id,    "relationship is set");
is($minimalx->clone->id, $clone->id,    "relationship works");
is($clone->origin->id,   $minimalx->id, "reverse relationship works");

# After reloading minimalx, it doesn't look cloneable anymore
ok(!$minimalx->can_be_duplicated, "doesn't look cloneable after reloading");
is($minimalx->duplicate, undef, "cannot clone after reloading");

# But cloning the clone should be possible after job state change
$clone->state(OpenQA::Jobs::Constants::CANCELLED);
$clones = $clone->duplicate({prio => 35});
my $second = $jobs->find($clones->{$clone->id}->{clone});
is($second->TEST,     "minimalx", "same test again");
is($second->priority, 35,         "with adjusted priority");

subtest 'handle settings when posting job' => sub {
    $products->create(
        {
            version     => '15-SP1',
            name        => '',
            distri      => 'sle',
            arch        => 'x86_64',
            description => '',
            flavor      => 'Installer-DVD',
            settings    => [
                {key => 'BUILD_SDK',    value => '%BUILD%'},
                {key => '+ISO_MAXSIZE', value => '4700372992'},
                {
                    key   => '+HDD_1',
                    value => 'SLES-%VERSION%-%ARCH%-%BUILD%@%MACHINE%-minimal_with_sdk%BUILD_SDK%_installed.qcow2'
                },
            ],
        });
    $testsuites->create(
        {
            name        => 'autoupgrade',
            description => '',
            settings    => [{key => 'ISO_MAXSIZE', value => '50000000'},],
        });

    my %new_jobs_post_params = (
        HDD_1       => 'foo.qcow2',
        DISTRI      => 'sle',
        VERSION     => '15-SP1',
        FLAVOR      => 'Installer-DVD',
        ARCH        => 'x86_64',
        TEST        => 'autoupgrade',
        MACHINE     => '64bit',
        BUILD       => '1234',
        ISO_MAXSIZE => '60000000',
    );

    subtest 'handle settings from Machine, Testsuite, Product variables' => sub {
        $t->post_ok('/api/v1/jobs', form => \%new_jobs_post_params)->status_is(200, 'Job posted');
        my $result = $jobs->find($t->tx->res->json->{id})->settings_hash;
        delete $result->{NAME};
        is_deeply(
            $result,
            {
                %new_jobs_post_params,
                HDD_1        => 'SLES-15-SP1-x86_64-1234@64bit-minimal_with_sdk1234_installed.qcow2',
                ISO_MAXSIZE  => '4700372992',
                BUILD_SDK    => '1234',
                QEMUCPU      => 'qemu64',
                BACKEND      => 'qemu',
                WORKER_CLASS => 'qemu_x86_64'
            },
            'expand specified Machine, TestSuite, Product variables and handle + in settings correctly'
        );
    };

    subtest 'circular reference settings' => sub {
        $new_jobs_post_params{BUILD} = '%BUILD_SDK%';
        $t->post_ok('/api/v1/jobs', form => \%new_jobs_post_params)->status_is(400, 'Job posted');
        like(
            $t->tx->res->json->{error},
            qr/The key (\w+) contains a circular reference, its value is %\w+%/,
            'circular reference exit successfully'
        );
    };
};

subtest 'do not re-generate settings when cloning job' => sub {
    my $job_settings = $jobs->search({test => 'autoupgrade'})->first->settings_hash;
    clone_job_apply_settings([qw(BUILD_SDK= ISO_MAXSIZE=)], 0, $job_settings, {});
    $t->post_ok('/api/v1/jobs', form => $job_settings)->status_is(200, 'Job cloned');
    my $new_job_settings = $jobs->find($t->tx->res->json->{id})->settings_hash;
    delete $job_settings->{is_clone_job};
    delete $new_job_settings->{NAME};
    is_deeply($new_job_settings, $job_settings, 'did not re-generate settings');
};

done_testing();
