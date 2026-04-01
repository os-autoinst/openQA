# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Scheduler::DynamicLimit;
use Mojo::Base -base, -signatures;

use List::Util qw(max min);
use Mojo::File 'path';
use OpenQA::Log qw(log_debug);
use OpenQA::Utils qw(load_avg);
use Time::HiRes 'time';
use Exporter 'import';

use constant {
    SCALE_UP_HYSTERESIS => 0.7,
    FAST_RAMP_UP_LOAD_FACTOR => 0.3,
    LOAD_THRESHOLD_FACTOR => 0.85,
    LOAD_CRITICAL_FACTOR => 1.5,
    STEP => 10,
    MIN => 50,
    INTERVAL => 60,
    EMERGENCY_STEP_MULTIPLIER => 3,
};

our @EXPORT_OK = qw(
  SCALE_UP_HYSTERESIS
  FAST_RAMP_UP_LOAD_FACTOR
  LOAD_THRESHOLD_FACTOR
  LOAD_CRITICAL_FACTOR
  STEP
  MIN
  INTERVAL
  EMERGENCY_STEP_MULTIPLIER
);

sub DEFAULTS ($self = undef) {
    return {
        dynamic_job_limit_load_threshold => 0,
        dynamic_job_limit_load_threshold_factor => LOAD_THRESHOLD_FACTOR,
        dynamic_job_limit_load_critical => 0,
        dynamic_job_limit_load_critical_factor => LOAD_CRITICAL_FACTOR,
        dynamic_job_limit_step => STEP,
        dynamic_job_limit_min => MIN,
        max_running_jobs => -1,
        dynamic_job_limit_interval => INTERVAL,
        dynamic_job_limit_scale_up_hysteresis => SCALE_UP_HYSTERESIS,
        dynamic_job_limit_fast_ramp_up_load_factor => FAST_RAMP_UP_LOAD_FACTOR,
    };
}

has effective_limit => undef;

# Forces the next current_limit() call to perform an adjustment regardless of interval.
sub force_next_adjustment ($self) { $self->{_last_adjusted} = 0 }

# Prevents adjustment until at least $seconds have elapsed (useful in tests).
sub block_adjustment_for ($self, $seconds = 9999) { $self->{_last_adjusted} = time + $seconds }

# Returns the number of online CPUs by counting processor entries in /proc/cpuinfo.
sub _nproc () {
    scalar grep { /^processor\s*:/ } split /\n/, path('/proc/cpuinfo')->slurp;
}

# Returns a resolved (non-zero) threshold, falling back to nproc * $factor.
sub _resolve_threshold ($configured, $factor) {
    return $configured if $configured > 0;
    state $nproc = _nproc();
    return $nproc > 0 ? $nproc * $factor : 10 * $factor;
}

# Extracts and resolves all dynamic-limit parameters from the scheduler config hashref.
# Returns a hash reference of typed values; this is the single point coupling
# DynamicLimit to the config key names.
sub _extract_config ($config) {
    my $defaults = DEFAULTS();
    return {
        threshold => _resolve_threshold(
            $config->{dynamic_job_limit_load_threshold} // $defaults->{dynamic_job_limit_load_threshold},
            $config->{dynamic_job_limit_load_threshold_factor} // $defaults->{dynamic_job_limit_load_threshold_factor}
        ),
        critical => _resolve_threshold(
            $config->{dynamic_job_limit_load_critical} // $defaults->{dynamic_job_limit_load_critical},
            $config->{dynamic_job_limit_load_critical_factor} // $defaults->{dynamic_job_limit_load_critical_factor}
        ),
        step => $config->{dynamic_job_limit_step} // $defaults->{dynamic_job_limit_step},
        min => $config->{dynamic_job_limit_min} // $defaults->{dynamic_job_limit_min},
        max => $config->{max_running_jobs} // $defaults->{max_running_jobs},
        interval => $config->{dynamic_job_limit_interval} // $defaults->{dynamic_job_limit_interval},
        scale_up_hysteresis => $config->{dynamic_job_limit_scale_up_hysteresis}
          // $defaults->{dynamic_job_limit_scale_up_hysteresis},
        fast_ramp_up_load_factor => $config->{dynamic_job_limit_fast_ramp_up_load_factor}
          // $defaults->{dynamic_job_limit_fast_ramp_up_load_factor},
    };
}

# Adjusts effective_limit based on current load and resolved params, returns the new value.
# Caller must ensure effective_limit is initialised before calling.
sub _adjust ($self, $load, $p) {
    my $current = $self->effective_limit;
    my ($l1, $l5, $l15) = @$load;
    my $load_max = max($l1, $l5, $l15);

    my $new;
    if ($load_max > $p->{critical}) {
        # Emergency: cut back aggressively
        $new = max($p->{min}, $current - $p->{step} * EMERGENCY_STEP_MULTIPLIER);
    }
    elsif ($l1 > $p->{threshold} && $l1 > $l5) {
        # Load rising above threshold: decrease conservatively
        $new = max($p->{min}, $current - $p->{step});
    }
    elsif ($load_max < $p->{threshold} * $p->{scale_up_hysteresis}) {
        # Load well below threshold on all horizons: increase conservatively
        # Double step for fast ramp-up if load is very low
        my $step = $load_max < $p->{threshold} * $p->{fast_ramp_up_load_factor} ? $p->{step} * 2 : $p->{step};
        $new = $p->{max} >= 0 ? min($p->{max}, $current + $step) : $current + $step;
    }
    else {
        $new = $current;
    }

    $self->effective_limit($new);
    log_debug(sprintf 'Dynamic job limit: %d (min: %d, max: %d, load: %.2f/%.2f/%.2f, threshold: %.2f, critical: %.2f)',
        $new, $p->{min}, $p->{max}, $l1, $l5, $l15, $p->{threshold}, $p->{critical});
    return $new;
}

# Returns the effective job limit, adjusting if the configured interval has elapsed.
# $config is the scheduler config hashref.
sub current_limit ($self, $config) {
    my $p = _extract_config($config);
    my $load = load_avg();
    # Initialize on first call
    $self->effective_limit($p->{min}) unless defined $self->effective_limit;

    my $now = time;
    if (@$load >= 3 && $now - ($self->{_last_adjusted} // 0) >= $p->{interval}) {
        $self->{_last_adjusted} = $now;
        $self->_adjust($load, $p);
    }
    return $self->effective_limit;
}

1;
