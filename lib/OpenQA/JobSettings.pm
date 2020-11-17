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

use File::Basename;
use Mojo::URL;
use Mojo::Util 'url_unescape';
use OpenQA::Log 'log_debug';
use OpenQA::Utils 'get_url_short';

sub generate_settings {
    my ($params) = @_;
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

    parse_url_settings($settings);
    handle_plus_in_settings($settings);
    return expand_placeholders($settings);
}

# replace %NAME% with $settings{NAME}
sub expand_placeholders {
    my ($settings) = @_;

    for my $value (values %$settings) {
        next unless defined $value;

        my %visited_top_level_placeholders;

        eval { $value =~ s/%(\w+)%/_expand_placeholder($settings, $1, \%visited_top_level_placeholders)/eg; };
        if ($@) {
            return "Error: $@";
        }
    }
    return undef;
}

sub _expand_placeholder {
    my ($settings, $key, $visited_placeholders_in_parent_scope) = @_;

    return '' unless defined $settings->{$key};

    my %visited_placeholders = %$visited_placeholders_in_parent_scope;
    if ($visited_placeholders{$key}++) {
        die "The key $key contains a circular reference, its value is $settings->{$key}.\n";
    }

    my $value = $settings->{$key};
    $value =~ s/%(\w+)%/_expand_placeholder($settings, $1, \%visited_placeholders)/eg;

    return $value;
}

# allow some messing with the usual precedence order. If anything
# sets +VARIABLE, that setting will be used as VARIABLE regardless
# (so a product or template +VARIABLE beats a post'ed VARIABLE).
# if *multiple* things set +VARIABLE, whichever comes highest in
# the usual precedence order wins.
sub handle_plus_in_settings {
    my ($settings) = @_;
    for (keys %$settings) {
        if (substr($_, 0, 1) eq '+') {
            $settings->{substr($_, 1)} = delete $settings->{$_};
        }
    }
}

# Given a hashref of settings, parse any whose names end in _URL
# to the short name, then if there is not already a setting with
# the short name, set it to the filename from the URL (with the
# compression extension removed in the case of _DECOMPRESS_URL).
# This has to happen *before* generate_jobs
sub parse_url_settings {
    my ($settings) = @_;
    for my $setting (keys %$settings) {
        my ($short, $do_extract) = get_url_short($setting);
        next unless ($short);
        next if defined($settings->{$short});
        # As this comes in from an API call, URL will be URI-encoded
        # This obviously creates a vuln if untrusted users can POST
        $settings->{$setting} = url_unescape($settings->{$setting});
        my $url      = $settings->{$setting};
        my $filename = Mojo::URL->new($url)->path->parts->[-1];
        if ($do_extract) {
            # if user wants to extract downloaded file, final filename
            # will have last extension removed
            $filename = fileparse($filename, qr/\.[^.]*/);
        }
        $settings->{$short} = $filename;
        if (!$settings->{$short}) {
            log_debug("Unable to get filename from $url. Ignoring $setting");
            delete $settings->{$short} unless $settings->{$short};
            next;
        }
    }
    return undef;
}

1;
