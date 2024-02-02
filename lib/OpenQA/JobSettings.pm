# Copyright 2019-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::JobSettings;

use Mojo::Base -strict, -signatures;

use File::Basename;
use Mojo::URL;
use Mojo::Util 'url_unescape';
use OpenQA::Log 'log_debug';
use OpenQA::Utils qw(asset_type_from_setting get_url_short);

sub generate_settings ($params) {
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
    if (my $machine = $params->{machine}) {
        $settings->{BACKEND} = $machine->backend;
        $settings->{MACHINE} = $machine->name;
    }

    # make sure that the DISTRI is lowercase
    $settings->{DISTRI} = lc($settings->{DISTRI}) if $settings->{DISTRI};

    # add properties from dedicated database columns to settings
    if (my $job_template = $params->{job_template}) {
        $settings->{TEST} = $job_template->name || $job_template->test_suite->name;
        $settings->{TEST_SUITE_NAME} = $job_template->test_suite->name;
        $settings->{JOB_DESCRIPTION} = $job_template->description if length $job_template->description;
    }

    parse_url_settings($settings);
    handle_plus_in_settings($settings);
    return expand_placeholders($settings);
}

# replace %NAME% with $settings{NAME} (but not %%NAME%%)
sub expand_placeholders ($settings) {
    for my $value (values %$settings) {
        next unless defined $value;
        my %visited_placeholders;
        eval { $value =~ s/(%+)(\w+)(%+)/_expand_placeholder($settings, $2, $1, $3, \%visited_placeholders)/eg };
        return "Error: $@" if $@;
    }
    return undef;
}

sub _expand_placeholder ($settings, $key, $start, $end, $visited_placeholders_in_parent_scope) {
    return '' unless defined $settings->{$key};

    my %visited_placeholders = %$visited_placeholders_in_parent_scope;
    die "The key $key contains a circular reference, its value is $settings->{$key}.\n"
      if $visited_placeholders{$key}++;

    # if the key is surrounded by more than one % on any side, return the key itself and strip one level of %
    return substr($start, 1) . ($key) . substr($end, 0, -1) unless $start eq '%' && $end eq '%';

    # otherwise, substitute the whole %…% expression with the value of the other setting
    my $value = $settings->{$key};
    $value =~ s/(%+)(\w+)(%+)/_expand_placeholder($settings, $2, $1, $3, \%visited_placeholders)/eg;
    return $value;
}

# allow some messing with the usual precedence order. If anything
# sets +VARIABLE, that setting will be used as VARIABLE regardless
# (so a product or template +VARIABLE beats a post'ed VARIABLE).
# if *multiple* things set +VARIABLE, whichever comes highest in
# the usual precedence order wins.
sub handle_plus_in_settings ($settings) {
    for (keys %$settings) {
        if (substr($_, 0, 1) eq '+') {
            $settings->{substr($_, 1)} = delete $settings->{$_};
        }
    }
}

# Given a hashref of settings, parse any whose names end in _URL
# to the short name, then if there is not already a setting with
# the short name and the setting is an asset type, set it to the
# filename from the URL (with the compression extension removed
# in the case of _DECOMPRESS_URL).
sub parse_url_settings ($settings) {
    for my $setting (keys %$settings) {
        my ($short, $do_extract) = get_url_short($setting);
        next unless ($short);
        next if defined($settings->{$short});
        # As this comes in from an API call, URL will be URI-encoded
        # This obviously creates a vuln if untrusted users can POST
        $settings->{$setting} = url_unescape($settings->{$setting});
        my $url = $settings->{$setting};
        my $filename = Mojo::URL->new($url)->path->parts->[-1];
        if ($do_extract) {
            # if user wants to extract downloaded file, final filename
            # will have last extension removed
            $filename = fileparse($filename, qr/\.[^.]*/);
        }
        if (!$filename) {
            log_debug("Unable to get filename from $url. Ignoring $setting");
            next;
        }
        # We shouldn't set the short setting for non-asset types
        unless (asset_type_from_setting($short, $filename)) {
            log_debug("_URL downloading only allowed for asset types! $short is not an asset type");
            next;
        }
        $settings->{$short} = $filename;
    }
    return undef;
}

1;
