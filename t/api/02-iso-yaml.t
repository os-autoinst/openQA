#!/usr/bin/env perl
# Copyright 2023 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '6';
use OpenQA::Test::Case;
use OpenQA::Test::Client 'client';
use OpenQA::Test::Utils 'schedule_iso';
use Mojo::File 'path';

OpenQA::Test::Case->new->init_data(fixtures_glob => '03-users.pl');
my $t = client(Test::Mojo->new('OpenQA::WebAPI'));
my $schema = $t->app->schema;
my $jobs = $schema->resultset('Jobs');
my %iso = (ISO => 'foo.iso', DISTRI => 'opensuse', VERSION => '13.1', FLAVOR => 'DVD', ARCH => 'i586', BUILD => '0091');

subtest 'schedule from yaml file: error cases' => sub {
    my $file = 'does-not-exist.yaml';
    my %args = (%iso, GROUP_ID => '0', SCENARIO_DEFINITIONS_YAML_FILE => $file, TEST => 'autoyast_btrfs');
    my $res = schedule_iso($t, \%args, 400);
    my $json = $res->json;
    like $json->{error},
      qr/Unable to load YAML:.*Could not open 'does-not-exist.yaml' for reading: No such file or directory/,
      'error when YAML file does not exist'
      or always_explain $json;
    is $json->{count}, 0, 'no jobs are scheduled when loading YAML fails' or always_explain $json;

    $file = "$FindBin::Bin/../data/09-schedule_from_file_incomplete.yaml";
    my @expected_errors
      = ('YAML validation failed:', 'machines: Expected object - got null', 'products: Expected object - got null');
    my $expected_errors = join '.*', @expected_errors;
    %args = (%iso, GROUP_ID => '0', SCENARIO_DEFINITIONS_YAML_FILE => $file, TEST => 'autoyast_btrfs');
    $res = schedule_iso($t, \%args, 400);
    $json = $res->json;
    like $json->{error}, qr|$expected_errors|s, 'error when YAML file is invalid' or always_explain $json;
    is $json->{count}, 0, 'no jobs are scheduled when validating YAML file fails' or always_explain $json;

    %args = (%iso, GROUP_ID => '0', SCENARIO_DEFINITIONS_YAML => path($file)->slurp, TEST => 'autoyast_btrfs');
    $res = schedule_iso($t, \%args, 400);
    $json = $res->json;
    like $json->{error}, qr|$expected_errors|s, 'error when YAML is invalid' or always_explain $json;
    is $json->{count}, 0, 'no jobs are scheduled when validating YAML fails' or always_explain $json;
};

subtest 'schedule from yaml file: case with machines/products and job dependencies' => sub {
    my $file = "$FindBin::Bin/../data/09-schedule_from_file.yaml";
    my %args = (%iso, GROUP_ID => '0', SCENARIO_DEFINITIONS_YAML_FILE => $file, TEST => 'autoyast_btrfs');
    my $res = schedule_iso($t, \%args, 200);
    my $json = $res->json;
    is $json->{count}, 2, 'two jobs were scheduled' or return always_explain $json;
    my $job_ids = $json->{ids};
    is @$job_ids, 2, 'two job IDs returned' or return always_explain $json;
    my $parent_job = $jobs->find($job_ids->[0]);
    is $parent_job->TEST, 'create_hdd', 'parent job for creating HDD created';
    my $parent_job_settings = $parent_job->settings_hash;
    is $parent_job_settings->{PUBLISH_HDD_1},
      'opensuse-13.1-i586-0091@aarch64-minimal_with_sdk0091_installed.qcow2',
      'settings of parent job were handled correctly';
    my $child_job = $jobs->find($job_ids->[1]);
    is $child_job->TEST, 'autoyast_btrfs', 'correct child job was created';
    my $child_job_settings = $child_job->settings_hash;
    is $child_job_settings->{HDD_1},
      'opensuse-13.1-i586-0091@aarch64-minimal_with_sdk0091_installed.qcow2',
      'settings of child job were handled correctly';
    ok !exists $parent_job_settings->{SCENARIO_DEFINITIONS_YAML_FILE},
      'SCENARIO_DEFINITIONS_YAML_FILE does not end up as job setting (1)';
    ok !exists $child_job_settings->{SCENARIO_DEFINITIONS_YAML_FILE},
      'SCENARIO_DEFINITIONS_YAML_FILE does not end up as job setting (2)';
    my @settings = ($parent_job_settings, $child_job_settings);
    subtest 'settings from machine definition present' => sub {
        for my $job_settings (@settings) {
            is $job_settings->{QEMU}, 'aarch64', "QEMU ($job_settings->{TEST})";
            is $job_settings->{QEMURAM}, 3072, "QEMURAM ($job_settings->{TEST})";
            is $job_settings->{UEFI}, 1, "UEFI ($job_settings->{TEST})";
        }
    } or always_explain \@settings;
    subtest 'settings from product definition present' => sub {
        for my $job_settings (@settings) {
            is $job_settings->{PRODUCT_SETTING}, 'foo', "PRODUCT_SETTING ($job_settings->{TEST})";
            is $job_settings->{DISTRI}, 'opensuse', "DISTRI ($job_settings->{TEST})";
            is $job_settings->{VERSION}, '13.1', "VERSION ($job_settings->{TEST})";
            is $job_settings->{FLAVOR}, 'DVD', "FLAVOR ($job_settings->{TEST})";
            is $job_settings->{ARCH}, 'i586', "ARCH ($job_settings->{TEST})";
        }
    } or always_explain \@settings;
    subtest 'worker class merged from different places' => sub {
        is $parent_job_settings->{WORKER_CLASS}, 'merged-with-machine-settings,qemu_aarch64', 'WORKER_CLASS (parent)';
        is $child_job_settings->{WORKER_CLASS}, 'job-specific-class,merged-with-machine-settings,qemu_aarch64',
          'WORKER_CLASS (child)';
    };
    is_deeply $child_job->dependencies->{parents}->{Chained}, [$parent_job->id], 'the dependency job was created';
};

subtest 'schedule from yaml file: most simple case of two explicitly specified jobs' => sub {
    my $file = "$FindBin::Bin/../data/09-schedule_from_file_minimal.yaml";
    my %args = (%iso, GROUP_ID => '0', SCENARIO_DEFINITIONS_YAML => path($file)->slurp, TEST => 'job1,job2');
    my $res = schedule_iso($t, \%args, 200);
    my $json = $res->json;
    is $json->{count}, 2, 'two jobs were scheduled without products/machines' or always_explain $json;
    my $job_ids = $json->{ids};
    is @$job_ids, 2, 'two job IDs returned' or return always_explain $json;
    $iso{DISTRI} = lc $iso{DISTRI};    # distri is expected to be converted to lower-case
    for my $i (1, 2) {
        my $job_id = $job_ids->[$i - 1];
        my $job = $jobs->find($job_id);
        my $job_settings = $job->settings_hash;
        my %expected = (
            %iso,
            TEST => "job$i",
            NAME => "0000000$job_id-opensuse-13.1-DVD-i586-Build0091-job$i",
            WORKER_CLASS => 'qemu_i586',
            "FOO_$i" => "bar$i",
        );
        is_deeply $job_settings, \%expected, "job$i scheduled with expected settings" or always_explain $job_settings;
        is $job->priority, $i, 'priority was set correctly';
    }
};

subtest 'schedule from yaml file: wildcard version' => sub {
    my $file = "$FindBin::Bin/../data/09-schedule_from_file_wildcard.yaml";
    my %args = (%iso, GROUP_ID => '0', SCENARIO_DEFINITIONS_YAML => path($file)->slurp, TEST => 'job1');
    my $res = schedule_iso($t, \%args, 200);
    my $json = $res->json;
    is $json->{count}, 1, 'one job was scheduled' or always_explain $json;
    my $job_ids = $json->{ids};
    is @$job_ids, 1, 'one job ID returned' or return always_explain $json;
    $iso{DISTRI} = lc $iso{DISTRI};    # distri is expected to be converted to lower-case
    my $job_id = $job_ids->[0];
    my $job_settings = $jobs->find($job_id)->settings_hash;
    my %expected = (
        %iso,
        TEST => "job1",
        NAME => "0000000$job_id-opensuse-13.1-DVD-i586-Build0091-job1",
        WORKER_CLASS => 'qemu_i586',
        FOO => 'bar',
        PRODUCT_SETTING => 'foo',
    );
    is_deeply $job_settings, \%expected, "job1 scheduled with expected settings" or always_explain $job_settings;
};

done_testing();
