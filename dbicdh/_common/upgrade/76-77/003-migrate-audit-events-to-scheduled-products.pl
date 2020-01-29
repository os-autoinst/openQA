#!/usr/bin/env perl

# Copyright (C) 2019 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use strict;
use DBIx::Class::DeploymentHandler;
use OpenQA::Schema;
use OpenQA::Schema::Result::ScheduledProducts;
use OpenQA::Utils;
use Mojo::JSON qw(decode_json encode_json);
use Try::Tiny;

sub {
    my ($schema) = @_;

    my $scheduled_products = $schema->resultset('ScheduledProducts');
    my $audit_events
      = $schema->resultset('AuditEvents')->search({event => 'iso_create'}, {order_by => {-asc => 'me.id'}},);

    OpenQA::Utils::log_info(
        'Migration of "iso_create" audit events to scheduled products is ongoing. This might take a while.');

    while (my $event = $audit_events->next) {
        my $event_id = $event->id;
        my $settings;
        try {
            $settings = decode_json($event->event_data);
        };
        if (!$settings) {
            OpenQA::Utils::log_warning(
                "Unable to read settings from 'iso_create' audit event with ID $event_id. Skipping its migration.");
            next;
        }

        my $scheduled_product = $scheduled_products->create(
            {
                distri  => $settings->{DISTRI}  // '',
                version => $settings->{VERSION} // '',
                flavor  => $settings->{FLAVOR}  // '',
                arch    => $settings->{ARCH}    // '',
                build   => $settings->{BUILD}   // '',
                iso     => $settings->{ISO}     // '',
                status  => OpenQA::Schema::Result::ScheduledProducts::SCHEDULED,
                settings  => $settings,
                user_id   => $event->user_id,
                t_created => $event->t_created,
            });

        # update the event_data so it only contains the product ID and the data is not duplicated
        $event->update({event_data => encode_json({scheduled_product_id => $scheduled_product->id})});
    }
  }
