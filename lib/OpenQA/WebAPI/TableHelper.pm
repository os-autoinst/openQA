# Copyright (C) 2019 SUSE LLC
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
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package OpenQA::WebAPI::TableHelper;

use strict;
use warnings;

sub prepare_settings {
    my ($settings_hparams) = @_;

    my @settings;
    my @keys;
    if ($settings_hparams) {
        for my $k (keys %$settings_hparams) {
            push(@settings, {key => $k, value => $settings_hparams->{$k}});
            push(@keys, $k);
        }
    }
    return {
        settings => \@settings,
        keys     => \@keys,
    };
}

sub update_settings {
    my ($settings, $dbix_result) = @_;

    for my $var (@{$settings->{settings}}) {
        $dbix_result->update_or_create_related(settings => $var);
    }
    $dbix_result->delete_related(settings => {key => {'not in' => $settings->{keys}}});
}

1;

=encoding utf-8

=head1 NAME

OpenQA::WebAPI::TableHelper - Defines helper used by OpenQA::WebAPI::Controller::API::V1::Table
and OpenQA::WebAPI::Controller::API::V1::JobTemplate

=cut
