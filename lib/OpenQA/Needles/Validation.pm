# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Needles::Validation;
use Mojo::Base -strict, -signatures;

use Exporter qw(import);
use Cwd qw(realpath);
use OpenQA::YAML qw(load_yaml);
use OpenQA::Log qw(log_warning);
use OpenQA::Utils qw(BUG_TRACKER_MARKERS);

our @EXPORT_OK = qw(validate_needle_name load_needle_validation_config);

my %SUPPORTED_RULES = (
    timestamp => \&_rule_timestamp,
    workaround_bugref => \&_rule_workaround_bugref,
    single_click_area => \&_rule_single_click_area,
);

sub load_needle_validation_config ($needledir, $instance_config) {
    my $config = {
        validation => $instance_config->{validation} // 'disabled',
        validation_rules => $instance_config->{validation_rules} // 'timestamp,workaround_bugref,single_click_area',
    };
    return $config unless defined $needledir && -d $needledir;
    my $real_needledir = realpath $needledir;
    return $config unless defined $real_needledir;
    my $real_yaml_path = realpath "$real_needledir/.openqa-needle-validation.yaml";
    return $config unless defined $real_yaml_path && -f $real_yaml_path;
    return $config unless index($real_yaml_path, $real_needledir) == 0;
    my $eval_success = eval {
        my $repo_config = load_yaml 'file', $real_yaml_path;
        if (ref $repo_config eq 'HASH') {
            if (defined $repo_config->{validation}) {
                $config->{validation} = $repo_config->{validation};
            }
            if (defined $repo_config->{validation_rules}) {
                my $rules = $repo_config->{validation_rules};
                $config->{validation_rules} = ref $rules eq 'ARRAY' ? join(',', @$rules) : $rules;
            }
        }
        1;
    };
    if (!$eval_success) {
        log_warning "Failed to load repo needle validation config from $real_yaml_path: $@";
    }
    return $config;
}

sub validate_needle_name ($needle, $json, $rules_str) {
    return [] unless defined $needle && defined $json && defined $rules_str;
    my @enabled_rules = split /\s*,\s*/, $rules_str;
    my @errors = grep { defined } map {
        my $validator = $SUPPORTED_RULES{$_};
        $validator ? $validator->($needle, $json) : undef
    } @enabled_rules;
    return \@errors;
}

sub _rule_timestamp ($needle, $json) {
    my $tmp = $needle;
    $tmp =~ s/[_-][0-9]{1,2}$//;
    my @parts = split /-/, $tmp;
    my $timestamp = $parts[-1] // '';
    $timestamp =~ s/_.*$//;
    if ($timestamp !~ /^[0-9]+$/ || length($timestamp) < 8 || $timestamp < 20_130_000) {
        return
"Needle '$needle' has missing or invalid timestamp suffix (valid suffixes: -YYYYMMDD or -YYYYMMDD_n with n=0…99) at the end!";
    }
    return undef;
}

sub _rule_workaround_bugref ($needle, $json) {
    my $properties = $json->{properties} // [];
    my $has_workaround
      = ref $properties eq 'ARRAY' ? grep { $_ eq 'workaround' } @$properties : ($properties =~ /workaround/);
    if ($has_workaround) {
        my $markers = BUG_TRACKER_MARKERS;
        unless ($needle =~ /((?:$markers)#?[A-Z0-9]+|jsc#?[A-Z]+-[0-9]+)/i) {
            return "Needle '$needle' includes a workaround tag but has no bug-ID in filename!";
        }
    }
    return undef;
}

sub _rule_single_click_area ($needle, $json) {
    my $areas = $json->{area} // [];
    if (ref $areas eq 'ARRAY') {
        my $click_count = grep { ($_->{type} // '') eq 'click' } @$areas;
        if ($click_count > 1) {
            return "Needle '$needle' has $click_count areas with type=click while only one is allowed!";
        }
    }
    return undef;
}

1;
