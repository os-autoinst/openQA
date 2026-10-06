# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings ':report_warnings';
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";

use utf8;
use Mojo::Base -signatures;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';
my $builder = Test::More->builder;
binmode $builder->output, ':encoding(UTF-8)';
binmode $builder->failure_output, ':encoding(UTF-8)';
binmode $builder->todo_output, ':encoding(UTF-8)';
use OpenQA::Constants qw(DEFAULT_MAX_JOB_TIME DEFAULT_TIMEOUT_SCALE);
use OpenQA::JobImpact qw(
  resolve_factors
  resources
  power_w
  assess
  upper_bound_seconds
  format_estimate
  format_cost
  format_carbon
);

subtest 'factor resolution and precedence levels' => sub {
    my $defaults = resolve_factors();
    is $defaults->{cpu_w}, 10, 'default cpu_w is 10';
    is $defaults->{slot_base_w}, 20, 'default slot_base_w is 20';
    is $defaults->{currency}, 'EUR', 'default currency is EUR';
    is $defaults->{allow_job_setting_overrides}, 0, 'default allow_job_setting_overrides is 0';
    is $defaults->{sources}->{cpu_w}, 'default', 'default source for cpu_w is default';
    is $defaults->{sources}->{currency}, 'default', 'default source for currency is default';

    my $ini_override = resolve_factors(config => {cpu_w => 12, currency => 'USD'},);
    is $ini_override->{cpu_w}, 12, 'openqa.ini overrides default cpu_w';
    is $ini_override->{currency}, 'USD', 'openqa.ini overrides default currency';
    is $ini_override->{mem_w}, 0.392, 'unspecified mem_w remains default';
    is $ini_override->{sources}->{cpu_w}, 'ini', 'source for ini-overridden cpu_w is ini';
    is $ini_override->{sources}->{currency}, 'ini', 'source for ini-overridden currency is ini';
    is $ini_override->{sources}->{mem_w}, 'default', 'source for untouched mem_w is default';

    my $full_config_override = resolve_factors(config => {%$defaults, cpu_w => 15},);
    is $full_config_override->{cpu_w}, 15, 'full config hash overrides cpu_w';
    is $full_config_override->{sources}->{cpu_w}, 'ini', 'source for modified key in full config is ini';
    is $full_config_override->{sources}->{mem_w}, 'default', 'source for unchanged key in full config is default';

    my $class_override = resolve_factors(
        config => {cpu_w => 12, slot_base_w => 25},
        by_class => {
            qemu_ppc64le => {slot_base_w => 40, cpu_w => 15},
            tap => {slot_base_w => 30},
        },
        worker_class => 'qemu_ppc64le,tap',
    );
    is $class_override->{slot_base_w}, 40, 'first matching worker class overrides slot_base_w';
    is $class_override->{cpu_w}, 15, 'first matching worker class overrides cpu_w';
    is $class_override->{sources}->{slot_base_w}, 'ini_class:qemu_ppc64le', 'source is ini_class:qemu_ppc64le';
    is $class_override->{sources}->{cpu_w}, 'ini_class:qemu_ppc64le', 'source is ini_class:qemu_ppc64le';

    my $second_class_match = resolve_factors(
        by_class => {tap => {slot_base_w => 35}},
        worker_class => 'unknown_class, tap',
    );
    is $second_class_match->{slot_base_w}, 35, 'subsequent class in comma list matches when first is absent';
    is $second_class_match->{sources}->{slot_base_w}, 'ini_class:tap', 'source indicates matched class';

    my $worker_props_override = resolve_factors(
        config => {cpu_w => 12},
        by_class => {qemu_ppc64le => {cpu_w => 15}},
        worker_class => 'qemu_ppc64le',
        worker_props => {
            JOB_IMPACT_CPU_W => 18,
            slot_base_w => 22,
            JOB_IMPACT_SLOT_POWER_W => 150,
            UNKNOWN_KEY => 999,
            JOB_IMPACT_INVALID => 'bad',
        },
    );
    is $worker_props_override->{cpu_w}, 18, 'worker props override worker class factor with prefix stripped';
    is $worker_props_override->{slot_base_w}, 22, 'worker props without prefix override factor';
    is $worker_props_override->{slot_power_w}, 150, 'worker props can set slot_power_w';
    is $worker_props_override->{sources}->{cpu_w}, 'worker', 'source is worker';
    is $worker_props_override->{sources}->{slot_base_w}, 'worker', 'source is worker';
    is $worker_props_override->{sources}->{slot_power_w}, 'worker', 'source is worker';
    ok !exists $worker_props_override->{unknown_key}, 'unknown worker prop key is not added';

    my $job_disallowed = resolve_factors(
        config => {cpu_w => 12, allow_job_setting_overrides => 0},
        job_settings => {
            JOB_IMPACT_CPU_W => 25,
            JOB_IMPACT_ALLOW_JOB_SETTING_OVERRIDES => 1,
        },
    );
    is $job_disallowed->{cpu_w}, 12, 'job settings cannot override factors when anti-gaming default is 0';
    is $job_disallowed->{allow_job_setting_overrides}, 0, 'job settings cannot self-enable overrides';
    is $job_disallowed->{sources}->{cpu_w}, 'ini', 'source remains ini when job override is disallowed';

    my $job_allowed = resolve_factors(
        config => {cpu_w => 12, allow_job_setting_overrides => 1},
        job_settings => {
            JOB_IMPACT_CPU_W => 25,
            JOB_IMPACT_MEM_W => 0.5,
            JOB_IMPACT_ALLOW_JOB_SETTING_OVERRIDES => 0,
            UNKNOWN_SETTING => 123,
            JOB_IMPACT_PUE => -1,
        },
    );
    is $job_allowed->{cpu_w}, 25, 'job settings override factors when allow_job_setting_overrides is 1';
    is $job_allowed->{mem_w}, 0.5, 'job settings override mem_w';
    is $job_allowed->{pue}, 1.5, 'negative numeric override in job settings is ignored';
    is $job_allowed->{sources}->{cpu_w}, 'job', 'source for job override is job';
    is $job_allowed->{sources}->{mem_w}, 'job', 'source for job override is job';
    is $job_allowed->{sources}->{pue}, 'default', 'source for rejected override remains default';
};

subtest 'resources parsing and default fallbacks' => sub {
    my @cases = (
        {
            desc => 'valid QEMUCPUS and QEMURAM in MB converted to GB',
            settings => {QEMUCPUS => 4, QEMURAM => 2048},
            factors => {},
            exp_vcpus => 4,
            exp_ram_gb => 2,
        },
        {
            desc => 'missing settings fall back to factor defaults',
            settings => {},
            factors => {default_vcpus => 2, default_ram_mb => 4096},
            exp_vcpus => 2,
            exp_ram_gb => 4,
        },
        {
            desc => 'non-numeric settings fall back to base defaults',
            settings => {QEMUCPUS => 'four', QEMURAM => 'two_g'},
            factors => {},
            exp_vcpus => 1,
            exp_ram_gb => 1,
        },
        {
            desc => 'negative and zero settings fall back to factor defaults',
            settings => {QEMUCPUS => 0, QEMURAM => -1024},
            factors => {default_vcpus => 1, default_ram_mb => 1024},
            exp_vcpus => 1,
            exp_ram_gb => 1,
        },
        {
            desc => 'no arguments provided falls back safely',
            settings => undef,
            factors => undef,
            exp_vcpus => 1,
            exp_ram_gb => 1,
        },
    );

    for my $case (@cases) {
        my $res = resources($case->{settings}, $case->{factors});
        is $res->{vcpus}, $case->{exp_vcpus}, "vcpus correct for $case->{desc}";
        is $res->{ram_gb}, $case->{exp_ram_gb}, "ram_gb correct for $case->{desc}";
    }
};

subtest 'power wattage calculation' => sub {
    my @cases = (
        {
            desc => 'standard component model with 1 vcpu and 1 gb ram',
            resources => {vcpus => 1, ram_gb => 1},
            factors => {slot_base_w => 20, cpu_w => 10, mem_w => 0.392},
            exp_power => 30.392,
        },
        {
            desc => 'component model with custom 4 vcpus and 8 gb ram',
            resources => {vcpus => 4, ram_gb => 8},
            factors => {slot_base_w => 20, cpu_w => 10, mem_w => 0.392},
            exp_power => 20 + (4 * 10) + (8 * 0.392),
        },
        {
            desc => 'slot_power_w overrides component model formula',
            resources => {vcpus => 8, ram_gb => 32},
            factors => {slot_power_w => 150, slot_base_w => 20, cpu_w => 10, mem_w => 0.392},
            exp_power => 150,
        },
        {
            desc => 'empty slot_power_w falls back to component model',
            resources => {vcpus => 2, ram_gb => 2},
            factors => {slot_power_w => '', slot_base_w => 20, cpu_w => 10, mem_w => 0.392},
            exp_power => 20 + 20 + 0.784,
        },
        {
            desc => 'no arguments provided falls back to default component power',
            resources => undef,
            factors => undef,
            exp_power => 30.392,
        },
    );

    for my $case (@cases) {
        my $power = power_w($case->{resources}, $case->{factors});
        is sprintf('%.3f', $power), sprintf('%.3f', $case->{exp_power}), "power wattage correct for $case->{desc}";
    }
};

subtest 'impact assessment calculation' => sub {
    my @cases = (
        {
            desc => 'standard 1 hour run with default factors',
            seconds => 3600,
            settings => {QEMUCPUS => 1, QEMURAM => 1024},
            factors => {
                slot_base_w => 20,
                cpu_w => 10,
                mem_w => 0.392,
                pue => 1.5,
                grid_g_per_kwh => 300,
                embodied_g_per_slot_hour => 1,
                eur_per_kwh => 0.20,
                hw_eur_per_slot_hour => 0.01,
                model_version => 1,
            },
            exp_energy => 0.045588,
            exp_carbon => 14.6764,
            exp_cost_energy => 0.0091176,
            exp_cost_hw => 0.01,
            exp_cost_total => 0.0191176,
        },
        {
            desc => 'fixed slot_power_w run for 2 hours',
            seconds => 7200,
            settings => {},
            factors => {
                slot_power_w => 150,
                pue => 1.5,
                grid_g_per_kwh => 300,
                embodied_g_per_slot_hour => 1,
                eur_per_kwh => 0.20,
                hw_eur_per_slot_hour => 0.01,
                model_version => 1,
            },
            exp_energy => 0.45,
            exp_carbon => 137,
            exp_cost_energy => 0.09,
            exp_cost_hw => 0.02,
            exp_cost_total => 0.11,
        },
        {
            desc => 'zero duration returns zero impact values',
            seconds => 0,
            settings => {},
            factors => {},
            exp_energy => 0,
            exp_carbon => 0,
            exp_cost_energy => 0,
            exp_cost_hw => 0,
            exp_cost_total => 0,
        },
    );

    for my $case (@cases) {
        my $res = assess(
            seconds => $case->{seconds},
            settings => $case->{settings},
            factors => $case->{factors},
        );
        is $res->{seconds}, $case->{seconds}, "seconds preserved for $case->{desc}";
        is sprintf('%.6f', $res->{energy_kwh}), sprintf('%.6f', $case->{exp_energy}),
          "energy_kwh within tolerance for $case->{desc}";
        is sprintf('%.4f', $res->{carbon_g}), sprintf('%.4f', $case->{exp_carbon}),
          "carbon_g within tolerance for $case->{desc}";
        is sprintf('%.6f', $res->{cost}->{energy}), sprintf('%.6f', $case->{exp_cost_energy}),
          "energy cost within tolerance for $case->{desc}";
        is sprintf('%.4f', $res->{cost}->{hardware}), sprintf('%.4f', $case->{exp_cost_hw}),
          "hardware cost within tolerance for $case->{desc}";
        is sprintf('%.6f', $res->{cost}->{total}), sprintf('%.6f', $case->{exp_cost_total}),
          "total cost within tolerance for $case->{desc}";
        is $res->{model_version}, 1, "model version recorded for $case->{desc}";
    }

    subtest 'invalid and undef duration rejection' => sub {
        is assess(seconds => undef), undef, 'undef seconds returns undef';
        is assess(seconds => -10), undef, 'negative seconds returns undef';
        is assess(seconds => 'invalid'), undef, 'non-numeric seconds returns undef';
    };
};

subtest 'upper bound duration calculation' => sub {
    my @cases = (
        {
            desc => 'empty settings default to 7200 seconds',
            settings => {},
            exp_seconds => 7200,
        },
        {
            desc => 'MAX_JOB_TIME multiplied by TIMEOUT_SCALE',
            settings => {MAX_JOB_TIME => 3600, TIMEOUT_SCALE => 2.5},
            exp_seconds => 9000,
        },
        {
            desc => 'non-numeric MAX_JOB_TIME falls back to 7200',
            settings => {MAX_JOB_TIME => 'foo', TIMEOUT_SCALE => 1.5},
            exp_seconds => 10800,
        },
        {
            desc => 'non-numeric TIMEOUT_SCALE falls back to 1',
            settings => {MAX_JOB_TIME => 1800, TIMEOUT_SCALE => 'bar'},
            exp_seconds => 1800,
        },
        {
            desc => 'zero or negative values fall back to defaults',
            settings => {MAX_JOB_TIME => -100, TIMEOUT_SCALE => 0},
            exp_seconds => 7200,
        },
        {
            desc => 'undef settings argument handled safely',
            settings => undef,
            exp_seconds => 7200,
        },
    );

    for my $case (@cases) {
        is upper_bound_seconds($case->{settings}), $case->{exp_seconds}, "upper bound correct for $case->{desc}";
    }
};

subtest 'formatting and unit boundary transitions' => sub {
    my @cost_cases = (
        {desc => 'zero cost', val => 0, curr => 'EUR', exp => '≈ 0 €'},
        {desc => 'small euro cost with two significant digits', val => 0.04234, curr => 'EUR', exp => '≈ 0.042 €'},
        {desc => 'very small euro cost', val => 0.00042, curr => 'EUR', exp => '≈ 0.00042 €'},
        {desc => 'magnitude transition at 0.0999', val => 0.0999, curr => 'EUR', exp => '≈ 0.10 €'},
        {desc => 'single digit euro cost', val => 1.234, curr => 'EUR', exp => '≈ 1.2 €'},
        {desc => 'double digit euro cost', val => 12.34, curr => 'EUR', exp => '≈ 12 €'},
        {desc => 'hundreds euro cost', val => 123.4, curr => 'EUR', exp => '≈ 120 €'},
        {desc => 'USD currency symbol', val => 0.052, curr => 'USD', exp => '≈ 0.052 $'},
        {desc => 'GBP currency symbol', val => 0.052, curr => 'GBP', exp => '≈ 0.052 £'},
        {desc => 'JPY currency symbol', val => 50, curr => 'JPY', exp => '≈ 50 ¥'},
        {desc => 'unmapped currency code', val => 10.6, curr => 'CHF', exp => '≈ 11 CHF'},
        {desc => 'negative cost handling', val => -0.042, curr => 'EUR', exp => '≈ -0.042 €'},
    );

    for my $case (@cost_cases) {
        is format_cost($case->{val}, $case->{curr}), $case->{exp}, "cost formatted for $case->{desc}";
    }

    my @carbon_cases = (
        {desc => 'zero carbon', val => 0, exp => '≈ 0 g CO₂e'},
        {desc => 'sub-gram carbon', val => 0.45, exp => '≈ 0.45 g CO₂e'},
        {desc => 'single digit grams', val => 5.4, exp => '≈ 5.4 g CO₂e'},
        {desc => 'double digit grams', val => 12, exp => '≈ 12 g CO₂e'},
        {desc => 'high grams below 1000 threshold', val => 950, exp => '≈ 950 g CO₂e'},
        {desc => 'transition boundary at 1000g to 1.0kg', val => 1000, exp => '≈ 1.0 kg CO₂e'},
        {desc => 'transition above 1000g to kg', val => 1200, exp => '≈ 1.2 kg CO₂e'},
        {desc => 'large kg carbon quantity', val => 15400, exp => '≈ 15 kg CO₂e'},
        {desc => 'negative carbon handling', val => -12, exp => '≈ -12 g CO₂e'},
    );

    for my $case (@carbon_cases) {
        is format_carbon($case->{val}), $case->{exp}, "carbon formatted for $case->{desc}";
    }

    subtest 'format_estimate combined presentation' => sub {
        my $sample_assessment = {
            cost => {total => 0.04234},
            carbon_g => 12.3,
        };
        is format_estimate($sample_assessment, 'EUR'), '≈ 0.042 € · ≈ 12 g CO₂e',
          'format_estimate returns dot-separated cost and carbon';
        is format_cost($sample_assessment->{cost}->{total}, 'EUR'), '≈ 0.042 €',
          'format_cost returns formatted cost part';
        is format_carbon($sample_assessment->{carbon_g}), '≈ 12 g CO₂e',
          'format_carbon returns formatted carbon part';

        my $cost_only = {cost => {total => 0.042}};
        is format_estimate($cost_only, 'EUR'), '≈ 0.042 €', 'assessment with only cost formats cost';

        my $carbon_only = {carbon_g => 1200};
        is format_estimate($carbon_only), '≈ 1.2 kg CO₂e', 'assessment with only carbon formats carbon';

        is format_estimate(0.042, 'EUR'), '≈ 0.042 €', 'numeric scalar passed to format_estimate formats as cost';
        is format_estimate('non_numeric'), undef, 'non-numeric non-ref returns undef';
        is format_estimate(undef), undef, 'undef assessment returns undef';
        is format_cost(undef), undef, 'undef cost returns undef';
        is format_cost('invalid'), undef, 'non-numeric cost returns undef';
        is format_carbon(undef), undef, 'undef carbon returns undef';
        is format_carbon('invalid'), undef, 'non-numeric carbon returns undef';
    };
};

subtest 'human review cost calculation in assess' => sub {
    my $factors_no_human = {
        cpu_w => 10,
        mem_w => 0.392,
        slot_base_w => 20,
        pue => 1.5,
        grid_g_per_kwh => 300,
        eur_per_kwh => 0.20,
        hw_eur_per_slot_hour => 0.01,
        embodied_g_per_slot_hour => 1,
    };
    my $res_no_human = assess(seconds => 3600, factors => $factors_no_human, result => 'failed');
    is $res_no_human->{cost}->{human}, undef, 'human cost undef when reviewer_eur_per_hour not set';

    my $factors_with_human = {
        %$factors_no_human,
        reviewer_eur_per_hour => 60,
        review_minutes_failed => 10,
        review_minutes_incomplete => 5,
        review_minutes_softfailed => 2,
        review_minutes_passed => 0,
    };

    my $failed_res = assess(seconds => 3600, factors => $factors_with_human, result => 'failed');
    is $failed_res->{cost}->{human}, 10, 'failed job adds 10 minutes human cost (10 EUR)';
    is $failed_res->{cost}->{total}, $failed_res->{cost}->{energy} + $failed_res->{cost}->{hardware} + 10,
      'human cost included in total cost';

    my $passed_res = assess(seconds => 3600, factors => $factors_with_human, result => 'passed');
    is $passed_res->{cost}->{human}, 0, 'passed job has 0 human cost';

    my $incomplete_res = assess(seconds => 3600, factors => $factors_with_human, result => 'incomplete');
    is $incomplete_res->{cost}->{human}, 5, 'incomplete job adds 5 minutes human cost (5 EUR)';

    my $softfailed_res = assess(seconds => 3600, factors => $factors_with_human, result => 'softfailed');
    is $softfailed_res->{cost}->{human}, 2, 'softfailed job adds 2 minutes human cost (2 EUR)';

    my $unknown_res = assess(seconds => 3600, factors => $factors_with_human, result => 'other');
    is $unknown_res->{cost}->{human}, 0, 'unconfigured result gives 0 human cost';
};

done_testing();
