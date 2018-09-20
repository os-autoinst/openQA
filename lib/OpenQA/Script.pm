# Copyright (C) 2018 SUSE LLC
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

package OpenQA::Script;
use strict;
use warnings;

require Exporter;
our (@ISA, @EXPORT);
@ISA    = qw(Exporter);
@EXPORT = qw(
  clone_job_apply_settings
);

use constant GLOBAL_SETTINGS => ('WORKER_CLASS');

use constant JOB_SETTING_OVERRIDES => {
    _GROUP    => '_GROUP_ID',
    _GROUP_ID => '_GROUP',
};

sub is_global_setting {
    return grep /^$_[0]$/, GLOBAL_SETTINGS;
}

sub clone_job_apply_settings {
    my ($argv, $depth, $settings, $options) = @_;

    delete $settings->{NAME};    # usually autocreated

    for my $arg (@$argv) {
        # split arg into key and value
        unless ($arg =~ /([A-Z0-9_]+)=(.*)/) {
            warn "arg $arg doesn't match";
            next;
        }
        my ($key, $value) = ($1, $2);

        next unless (is_global_setting($key) or $depth == 0 or $options->{'parental-inheritance'});

        # delete key if value empty
        if (!defined $value || $value eq '') {
            delete $settings->{$key};
            next;
        }

        # assign value to key, delete overrides
        $settings->{$key} = $value;
        if (my $override = JOB_SETTING_OVERRIDES->{$key}) {
            delete $settings->{$override};
        }
    }
}

1;
