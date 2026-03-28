# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Scheduler::DynamicLimit;
use Mojo::Base -base, -signatures;

use List::Util qw(max min);
use Mojo::File 'path';
use OpenQA::Log qw(log_debug);
use OpenQA::Utils qw(load_avg);
use Time::HiRes 'time';

# Fraction of threshold below which all load averages must fall to scale up.
use constant SCALE_UP_HYSTERESIS => 0.7;
# Multiplier applied to step on an emergency (critical) cutback.
use constant EMERGENCY_STEP_MULTIPLIER => 3;

has effective_limit => undef;
has _last_adjusted => 0;

# Forces the next current_limit() call to perform an adjustment regardless of interval.
sub force_next_adjustment ($self) { $self->_last_adjusted(0) }

# Prevents adjustment until at least $seconds have elapsed (useful in tests).
sub block_adjustment_for ($self, $seconds = 9999) { $self->_last_adjusted(time + $seconds) }

# Returns the number of online CPUs by counting processor entries in /proc/cpuinfo.
sub _nproc () {    # uncoverable statement
    scalar grep { /^processor\s*:/ } split /\n/, path('/proc/cpuinfo')->slurp;    # uncoverable statement
}

# Returns a resolved (non-zero) threshold, falling back to nproc * $factor.
sub _resolve_threshold ($configured, $factor) {
    return $configured if $configured > 0;
    my $nproc = _nproc();
    return $nproc > 0 ? $nproc * $factor : 10 * $factor;
}

# Extracts and resolves all dynamic-limit parameters from the scheduler config hashref.
# Returns a plain hash of typed values; this is the single point coupling DynamicLimit
# to the config key names.
sub _extract_config ($config) {
    return (
        threshold => _resolve_threshold($config->{dynamic_job_limit_load_threshold}, 0.85),
        critical => _resolve_threshold($config->{dynamic_job_limit_load_critical}, 1.5),
        step => $config->{dynamic_job_limit_step},
        min => $config->{dynamic_job_limit_min},
        max => $config->{max_running_jobs},
        interval => $config->{dynamic_job_limit_interval},
    );
}

# Adjusts effective_limit based on current load and resolved params, returns the new value.
# Caller must ensure effective_limit is initialised before calling.
sub _adjust ($self, $load, %p) {
    my $current = $self->effective_limit;
    my ($l1, $l5, $l15) = @{$load};

    my $new;
    if (max($l1, $l5, $l15) > $p{critical}) {
        # Emergency: cut back aggressively
        $new = max($p{min}, $current - $p{step} * EMERGENCY_STEP_MULTIPLIER);
    }
    elsif ($l1 > $p{threshold} && $l1 > $l5) {
        # Load rising above threshold: decrease conservatively
        $new = max($p{min}, $current - $p{step});
    }
    elsif (max($l1, $l5, $l15) < $p{threshold} * SCALE_UP_HYSTERESIS) {
        # Load well below threshold on all horizons: increase conservatively
        $new = $p{max} >= 0 ? min($p{max}, $current + $p{step}) : $current + $p{step};
    }
    else {
        $new = $current;
    }

    $self->effective_limit($new);
    log_debug(sprintf 'Dynamic job limit: %d (load: %.2f/%.2f/%.2f, threshold: %.2f, critical: %.2f)',
        $new, $l1, $l5, $l15, $p{threshold}, $p{critical});
    return $new;
}

# Returns the effective job limit, adjusting if the configured interval has elapsed.
# $config is the scheduler config hashref.
sub current_limit ($self, $config) {
    my %p = _extract_config($config);
    my $load = load_avg();
    # Initialize on first call
    $self->effective_limit($p{min}) unless defined $self->effective_limit;

    my $now = time;
    if (@$load >= 3 && $now - $self->_last_adjusted >= $p{interval}) {
        $self->_last_adjusted($now);
        $self->_adjust($load, %p);
    }
    return $self->effective_limit;
}

1;
