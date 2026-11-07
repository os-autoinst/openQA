# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::JobSettings::Lifecycle;

use Mojo::Base -strict, -signatures;
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
    my $cached = $config->{misc_limits}->{job_settings_lifecycle_rules};
    return $cached if defined $cached;

    my $rules_hash = $config->{job_settings_lifecycle};
    my @parsed_rules = map { _parse_rule($_, $rules_hash->{$_}) } sort keys %$rules_hash;
    return $config->{misc_limits}->{job_settings_lifecycle_rules} = \@parsed_rules;
}

sub check_setting ($key, $value, $rules) {
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
    return map { check_setting($_, $settings->{$_}, $rules) } sort keys %$settings;
}

sub validate_settings_for_submission ($settings, $config) {
    my @errors = grep { $_->{level} eq 'error' } check_settings($settings, parse_lifecycle_rules($config));
    return undef unless @errors;
    return join "\n",
      map { sprintf "Setting '%s' has deprecated value '%s': %s", $_->{key}, $_->{value} // '', $_->{explanation} }
      @errors;
}

sub apply_lifecycle_prio ($settings, $new_job_args, $throttling_info, $rules) {
    for my $match (check_settings($settings, $rules)) {
        my $adj = $match->{prio_adjustment};
        next unless defined $adj;
        $new_job_args->{priority} //= 0;
        $new_job_args->{priority} += $adj;
        my $sign = $adj >= 0 ? '+' : '';
        push @$throttling_info, sprintf '%s [%s%s: value %s]', $match->{key}, $sign, $adj, $match->{value} // '';
    }
}

sub lifecycle_matches ($config, $settings) {
    return check_settings($settings, parse_lifecycle_rules($config));
}

sub worst_level ($matches) {
    my %levels = map { $_->{level} => 1 } @$matches;
    return $levels{error} ? 'error' : $levels{warning} ? 'warning' : $levels{info} ? 'info' : undef;
}

1;
