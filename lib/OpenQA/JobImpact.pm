# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::JobImpact;
use Mojo::Base -strict, -signatures;

use Exporter 'import';
use POSIX qw(floor);
use Scalar::Util 'looks_like_number';
use OpenQA::Constants qw(DEFAULT_MAX_JOB_TIME DEFAULT_TIMEOUT_SCALE);
use OpenQA::Setup;

our @EXPORT_OK = qw(
  resolve_factors
  resources
  power_w
  assess
  upper_bound_seconds
  format_estimate
  format_cost
  format_carbon
);

my %CURRENCY_SYMBOLS = (
    EUR => '€',
    USD => '$',
    GBP => '£',
    JPY => '¥',
);

sub _is_valid_factor_value ($key, $val) {
    return 0 unless defined $val;
    if ($key eq 'slot_power_w' || $key eq 'methodology_url') {
        return 1 if $val eq '';
    }
    if ($key =~ /^(currency|methodology_url)$/) {
        return 1;
    }
    return looks_like_number($val) && $val >= 0;
}

sub resolve_factors (%args) {
    my $defaults = $args{defaults} // OpenQA::Setup::default_config()->{job_impact};
    my $config = $args{config} // {};
    my $by_class = $args{by_class} // {};
    my $worker_class = $args{worker_class} // '';
    my $worker_props = $args{worker_props} // {};
    my $job_settings = $args{job_settings} // {};

    my %factors = %$defaults;
    my %sources = map { $_ => 'default' } keys %factors;

    my $is_full_config = scalar keys %$config >= scalar keys %$defaults;
    for my $k (keys %$config) {
        my $v = $config->{$k};
        next if !defined $v;
        next if $v eq '' && $k ne 'slot_power_w' && $k ne 'methodology_url';
        next unless _is_valid_factor_value($k, $v);
        if (!$is_full_config || (!defined $defaults->{$k} || $v ne $defaults->{$k})) {
            $factors{$k} = $v;
            $sources{$k} = 'ini';
        }
    }

    my @classes = split /\s*,\s*/, $worker_class;
    for my $c (@classes) {
        next unless $c && exists $by_class->{$c} && ref $by_class->{$c} eq 'HASH';
        my $class_factors = $by_class->{$c};
        for my $k (keys %$class_factors) {
            my $v = $class_factors->{$k};
            next if !defined $v;
            next if $v eq '' && $k ne 'slot_power_w' && $k ne 'methodology_url';
            next unless _is_valid_factor_value($k, $v);
            $factors{$k} = $v;
            $sources{$k} = "ini_class:$c";
        }
        last;
    }

    for my $raw_k (keys %$worker_props) {
        my $v = $worker_props->{$raw_k};
        next if !defined $v;
        next if $v eq '' && lc($raw_k) !~ /slot_power_w/;
        my $k = lc $raw_k;
        $k =~ s/^job_impact_//;
        next unless exists $defaults->{$k};
        next unless _is_valid_factor_value($k, $v);
        $factors{$k} = $v;
        $sources{$k} = 'worker';
    }

    if ($factors{allow_job_setting_overrides}) {
        for my $raw_k (keys %$job_settings) {
            my $v = $job_settings->{$raw_k};
            next if !defined $v;
            next if $v eq '' && lc($raw_k) !~ /slot_power_w/;
            my $k = lc $raw_k;
            $k =~ s/^job_impact_//;
            next if $k eq 'allow_job_setting_overrides';
            next unless exists $defaults->{$k};
            next unless _is_valid_factor_value($k, $v);
            $factors{$k} = $v;
            $sources{$k} = 'job';
        }
    }

    return {%factors, sources => \%sources};
}

sub resources ($settings = {}, $factors = {}) {
    $settings //= {};
    $factors //= {};

    my $default_vcpus = $factors->{default_vcpus} // 1;
    my $vcpus = $settings->{QEMUCPUS};
    $vcpus = (defined $vcpus && looks_like_number($vcpus) && $vcpus > 0) ? $vcpus + 0 : $default_vcpus + 0;

    my $default_ram_mb = $factors->{default_ram_mb} // 1024;
    my $ram_mb = $settings->{QEMURAM};
    $ram_mb = (defined $ram_mb && looks_like_number($ram_mb) && $ram_mb > 0) ? $ram_mb + 0 : $default_ram_mb + 0;
    my $ram_gb = $ram_mb / 1024;

    return {vcpus => $vcpus, ram_gb => $ram_gb};
}

sub power_w ($resources = {}, $factors = {}) {
    $resources //= {};
    $factors //= {};

    if (defined $factors->{slot_power_w} && looks_like_number($factors->{slot_power_w}) && $factors->{slot_power_w} > 0)
    {
        return $factors->{slot_power_w} + 0;
    }

    my $slot_base_w = $factors->{slot_base_w} // 20;
    my $cpu_w = $factors->{cpu_w} // 10;
    my $mem_w = $factors->{mem_w} // 0.392;

    my $vcpus = $resources->{vcpus} // 1;
    my $ram_gb = $resources->{ram_gb} // 1;

    return $slot_base_w + ($vcpus * $cpu_w) + ($ram_gb * $mem_w);
}

sub assess (%args) {
    my $seconds = $args{seconds};
    return undef if !defined $seconds || !looks_like_number($seconds) || $seconds < 0;

    my $factors = $args{factors} // {};
    my $resources = $args{resources} // resources($args{settings} // {}, $factors);

    my $hours = $seconds / 3600;
    my $pue = $factors->{pue} // 1.5;
    my $power = power_w($resources, $factors);
    my $energy_kwh = ($power * $hours * $pue) / 1000;

    my $grid_g_per_kwh = $factors->{grid_g_per_kwh} // 300;
    my $embodied_g_per_slot_hour = $factors->{embodied_g_per_slot_hour} // 1;
    my $carbon_g = ($energy_kwh * $grid_g_per_kwh) + ($embodied_g_per_slot_hour * $hours);

    my $eur_per_kwh = $factors->{eur_per_kwh} // 0.20;
    my $hw_eur_per_slot_hour = $factors->{hw_eur_per_slot_hour} // 0.01;
    my $cost_energy = $energy_kwh * $eur_per_kwh;
    my $cost_hardware = $hw_eur_per_slot_hour * $hours;
    my $cost_total = $cost_energy + $cost_hardware;

    my $cost_human;
    if (   defined $factors->{reviewer_eur_per_hour}
        && looks_like_number($factors->{reviewer_eur_per_hour})
        && $factors->{reviewer_eur_per_hour} > 0)
    {
        my $res = lc($args{result} // '');
        my $mins = $factors->{"review_minutes_$res"} // 0;
        $cost_human = ($mins * $factors->{reviewer_eur_per_hour}) / 60.0;
        $cost_total += $cost_human;
    }

    my $model_version = $factors->{model_version} // 1;

    return {
        seconds => $seconds + 0,
        energy_kwh => $energy_kwh,
        carbon_g => $carbon_g,
        cost => {
            energy => $cost_energy,
            hardware => $cost_hardware,
            human => $cost_human,
            total => $cost_total,
        },
        model_version => $model_version + 0,
    };
}

sub upper_bound_seconds ($settings = {}) {
    $settings //= {};
    my $max_job_time = $settings->{MAX_JOB_TIME};
    $max_job_time = DEFAULT_MAX_JOB_TIME
      if !defined $max_job_time || !looks_like_number $max_job_time || $max_job_time <= 0;
    my $scale = $settings->{TIMEOUT_SCALE};
    $scale = DEFAULT_TIMEOUT_SCALE if !defined $scale || !looks_like_number $scale || $scale <= 0;
    return $max_job_time * $scale;
}

sub _round_sig_digits ($val, $sig_digits = 2) {
    return '0' if !defined $val || $val == 0;
    my $sign = $val < 0 ? '-' : '';
    $val = abs $val;

    my $exp = floor(log($val) / log 10);
    my $decimals = $sig_digits - 1 - $exp;
    if ($decimals > 0) {
        my $res = sprintf '%.*f', $decimals, $val;
        if ($res >= 10**($exp + 1)) {
            $decimals--;
            $res = $decimals > 0 ? (sprintf '%.*f', $decimals, $val) : (sprintf '%.0f', $val);
        }
        return "$sign$res";
    }
    else {
        my $scale = 10**(-$decimals);
        my $scaled = sprintf '%.0f', $val / $scale;
        my $res = sprintf '%.0f', $scaled * $scale;
        return "$sign$res";
    }
}

sub format_cost ($cost, $currency = 'EUR') {
    return undef if !defined $cost || !looks_like_number $cost;
    $currency //= 'EUR';
    my $symbol = $CURRENCY_SYMBOLS{uc $currency} // $currency;
    return '≈ ' . _round_sig_digits($cost, 2) . " $symbol";
}

sub format_carbon ($carbon_g) {
    return undef if !defined $carbon_g || !looks_like_number $carbon_g;
    if ($carbon_g >= 1000) {
        return '≈ ' . _round_sig_digits($carbon_g / 1000, 2) . ' kg CO₂e';
    }
    return '≈ ' . _round_sig_digits($carbon_g, 2) . ' g CO₂e';
}

sub format_estimate ($assessment, $currency = 'EUR') {
    return undef unless defined $assessment;
    if (!ref $assessment) {
        return format_cost($assessment, $currency) if looks_like_number $assessment;
        return undef;
    }
    my $cost = $assessment->{cost};
    my $cost_val = ref $cost eq 'HASH' ? $cost->{total} : $cost;
    my $carbon_val = $assessment->{carbon_g};

    my $formatted_cost = defined $cost_val ? format_cost($cost_val, $currency) : undef;
    my $formatted_carbon = defined $carbon_val ? format_carbon($carbon_val) : undef;

    if (defined $formatted_cost && defined $formatted_carbon) {
        return "$formatted_cost · $formatted_carbon";
    }
    return $formatted_cost // $formatted_carbon;
}

1;
