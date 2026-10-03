# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::JobSettings::Lifecycle;

use Mojo::Base -strict, -signatures;
use Scalar::Util qw(looks_like_number);
use Feature::Compat::Try;
use OpenQA::Log qw(log_warning);

use Exporter 'import';

our @EXPORT_OK = qw(
  parse_lifecycle_rules
  check_setting
  check_settings
  validate_settings_for_submission
  apply_lifecycle_prio
  lifecycle_matches
  worst_level
);

use constant ALLOWED_LEVELS => {info => 1, warning => 1, error => 1};

sub _parse_rule ($rule_id, $rule_str) {
    return () unless defined $rule_str;

    my @parts = split /(?<!\\):/, $rule_str, 4;
    if (@parts < 4 || grep { $_ eq '' } @parts[0 .. 2]) {
        log_warning("Invalid lifecycle rule format for '$rule_id': '$rule_str'");
        return ();
    }

    my ($key, $pattern, $level, $remaining) = @parts;
    if (!ALLOWED_LEVELS->{$level}) {
        log_warning("Invalid lifecycle rule level '$level' for '$rule_id': '$rule_str'");
        return ();
    }

    my ($op, $regex_str) = $pattern =~ /^(!~|=~)(.*)$/ ? ($1, $2) : ('=~', $pattern);
    $regex_str =~ s/\\:/:/g;
    my $compiled_regex;
    try { $compiled_regex = qr/$regex_str/ }
    catch ($e) {
        log_warning("Invalid lifecycle rule regex for '$rule_id': '$rule_str'");
        return ();
    }

    my ($prio, $explanation) = $remaining =~ /^([+-]?\d+):(.*)$/ ? (0 + $1, $2) : (undef, $remaining);
    return {
        id => $rule_id,
        key => $key,
        op => $op,
        regex => $compiled_regex,
        regex_str => $regex_str,
        level => $level,
        prio => $prio,
        explanation => $explanation,
    };
}

sub parse_lifecycle_rules ($config) {
    return [] unless $config && ref $config eq 'HASH';
    return $config->{misc_limits}->{job_settings_lifecycle_rules}
      if ref $config->{misc_limits} eq 'HASH' && defined $config->{misc_limits}->{job_settings_lifecycle_rules};

    my $rules_hash = $config->{job_settings_lifecycle};
    unless (ref $rules_hash eq 'HASH') {
        $config->{misc_limits} = {} unless ref $config->{misc_limits} eq 'HASH';
        return $config->{misc_limits}->{job_settings_lifecycle_rules} = [];
    }

    my @parsed_rules = map { _parse_rule($_, $rules_hash->{$_}) } sort keys %$rules_hash;

    $config->{misc_limits} = {} unless ref $config->{misc_limits} eq 'HASH';
    $config->{misc_limits}->{job_settings_lifecycle_rules} = \@parsed_rules;
    return \@parsed_rules;
}

sub check_setting ($key, $value, $rules) {
    my @empty;
    return @empty unless defined $key && ref $rules eq 'ARRAY';
    my $val_str = $value // '';

    return map {
        ($_->{op} eq '=~' ? ($val_str =~ $_->{regex}) : ($val_str !~ $_->{regex}))
          ? {
            key => $key,
            value => $value,
            level => $_->{level},
            explanation => $_->{explanation},
            prio_adjustment => $_->{prio},
          }
          : ()
    } grep { $_->{key} eq $key } @$rules;
}

sub check_settings ($settings, $rules) {
    my @empty;
    return @empty unless defined $settings && ref $rules eq 'ARRAY';

    if (ref $settings eq 'HASH') {
        return map { check_setting($_, $settings->{$_}, $rules) } sort keys %$settings;
    }
    elsif (ref $settings eq 'ARRAY') {
        if (@$settings && ref $settings->[0] eq 'HASH') {
            return map { check_setting($_->{key}, $_->{value}, $rules) } grep { defined $_->{key} } @$settings;
        }
        else {
            return
              map { check_setting($settings->[$_], $settings->[$_ + 1], $rules) } grep { $_ % 2 == 0 } 0 .. $#$settings;
        }
    }
    return @empty;
}

sub validate_settings_for_submission ($settings, $rules_or_config) {
    return undef unless defined $rules_or_config;
    my $rules = ref $rules_or_config eq 'HASH' ? parse_lifecycle_rules($rules_or_config) : $rules_or_config;
    my @matches = check_settings($settings, $rules);
    my @errors = grep { $_->{level} eq 'error' } @matches;
    return undef unless @errors;
    return join "\n",
      map { sprintf "Setting '%s' has deprecated value '%s': %s", $_->{key}, $_->{value} // '', $_->{explanation} }
      @errors;
}

sub apply_lifecycle_prio ($settings, $new_job_args, $throttling_info, $rules) {
    return unless ref $rules eq 'ARRAY';
    my @matches = check_settings($settings, $rules);
    for my $match (@matches) {
        my $adj = $match->{prio_adjustment};
        next unless defined $adj && looks_like_number($adj);
        $new_job_args->{priority} //= 0;
        $new_job_args->{priority} += $adj;
        my $sign = $adj >= 0 ? '+' : '';
        push @$throttling_info, sprintf '%s [%s%s: value %s]', $match->{key}, $sign, $adj, $match->{value} // '';
    }
}

sub lifecycle_matches ($config, $settings) {
    my $rules = parse_lifecycle_rules($config);
    return check_settings($settings, $rules);
}

sub worst_level ($matches) {
    return undef unless $matches;
    my $array_ref = ref $matches eq 'ARRAY' ? $matches : [$matches];
    my %levels = map { $_->{level} => 1 } @$array_ref;
    return $levels{error} ? 'error' : $levels{warning} ? 'warning' : $levels{info} ? 'info' : undef;
}

1;
