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

sub is_global_setting {
    return grep /^$_[0]$/, GLOBAL_SETTINGS;
}

sub clone_job_apply_settings {
    my ($argv, $depth, $settings, $options) = @_;

    my %overrides = (
        _GROUP    => '_GROUP_ID',
        _GROUP_ID => '_GROUP',
    );
    delete $settings->{NAME};    # usually autocreated

    for my $arg (@$argv) {
        if ($arg =~ /([A-Z0-9_]+)=(.*)/) {
            if (is_global_setting($1) or $depth == 0 or $options->{'parental-inheritance'}) {
                if (defined $2) {
                    $settings->{$1} = $2;
                    if (my $override = $overrides{$1}) {
                        delete $settings->{$override};
                    }
                }
                else {
                    delete $settings->{$1};
                }
            }
        }
        else {
            warn "arg $arg doesn't match";
        }
    }
}

1;
