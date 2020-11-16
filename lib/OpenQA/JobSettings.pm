# Copyright (C) 2019-2020 SUSE LLC
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
# You should have received a copy of the GNU General Public License

package OpenQA::JobSettings;

use strict;
use warnings;

sub generate_settings {
    my ($params, $destructive, $definitive) = @_;
    $destructive //= 1;
    $definitive //= 1;
    my $settings = $params->{settings};
    my @worker_class;
    for my $entity (qw (product machine test_suite job_template)) {
        next unless $params->{$entity};
        my @entity_settings = $params->{$entity}->settings;
        for my $setting (@entity_settings) {
            if ($setting->key eq 'WORKER_CLASS') {
                push @worker_class, $setting->value;
                next;
            }
            $settings->{$setting->key} = $setting->value;
        }
    }
    $settings->{WORKER_CLASS} = join ',', sort @worker_class if @worker_class > 0;
    if (my $input_args = $params->{input_args}) {
        $settings->{uc $_} = $input_args->{$_} for keys %$input_args;
    }

    # Prevent the MACHINE from being overridden by input args when doing isos post
    if (my $machine = $params->{'machine'}) {
        $settings->{BACKEND} = $machine->backend;
        $settings->{MACHINE} = $machine->name;
    }

    # make sure that the DISTRI is lowercase
    $settings->{DISTRI} = lc($settings->{DISTRI}) if $settings->{DISTRI};

    # add properties from dedicated database columns to settings
    if (my $job_template = $params->{job_template}) {
        $settings->{TEST}            = $job_template->name || $job_template->test_suite->name;
        $settings->{TEST_SUITE_NAME} = $job_template->test_suite->name;
        $settings->{JOB_DESCRIPTION} = $job_template->description if length $job_template->description;
    }

    handle_plus_in_settings($settings, $destructive);
    return expand_placeholders($settings, $definitive);
}

# replace %NAME% with $settings{NAME}. if "definitive" is true, then
# if $settings{NAME} is not set, we replace with an empty string. If
# "definitive" is false, then if it is not set, we leave the
# placeholder in place.
sub expand_placeholders {
    my ($settings, $definitive) = @_;
    $definitive //= 1;

    for my $value (values %$settings) {
        next unless defined $value;

        my %visited_top_level_placeholders;

        eval { $value =~ s/%(\w+)%/_expand_placeholder($settings, $definitive, $1, \%visited_top_level_placeholders)/eg; };
        if ($@) {
            return "Error: $@";
        }
    }
    return undef;
}

sub _expand_placeholder {
    my ($settings, $definitive, $key, $visited_placeholders_in_parent_scope) = @_;

    unless (defined $settings->{$key}) {
        return '' if $definitive;
        return '%' . $key . '%';
    }

    my %visited_placeholders = %$visited_placeholders_in_parent_scope;
    if ($visited_placeholders{$key}++) {
        die "The key $key contains a circular reference, its value is $settings->{$key}.\n";
    }

    my $value = $settings->{$key};
    $value =~ s/%(\w+)%/_expand_placeholder($settings, $definitive, $1, \%visited_placeholders)/eg;

    return $value;
}

# allow some messing with the usual precedence order. If anything
# sets +VARIABLE, that setting will be used as VARIABLE regardless
# (so a product or template +VARIABLE beats a post'ed VARIABLE).
# if *multiple* things set +VARIABLE, whichever comes highest in
# the usual precedence order wins.
sub handle_plus_in_settings {
    my ($settings, $destructive) = @_;
    $destructive //= 1;
    for (keys %$settings) {
        if (substr($_, 0, 1) eq '+') {
            $settings->{substr($_, 1)} = $settings->{$_};
            delete $settings->{$_} if $destructive;
        }
    }
}

1;
