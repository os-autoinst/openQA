#!/usr/bin/env perl

# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use strict;
use DBIx::Class::DeploymentHandler;
use OpenQA::Schema;
use OpenQA::Schema::Result::ScheduledProducts;
use OpenQA::Log qw(log_info log_warning);
use OpenQA::Utils;
use Mojo::JSON qw(decode_json encode_json);
use Try::Tiny;

sub {
    my ($schema) = @_;

    my $scheduled_products = $schema->resultset('ScheduledProducts');
    my $audit_events
      = $schema->resultset('AuditEvents')->search({event => 'iso_create'}, {order_by => {-asc => 'me.id'}},);

    log_info('Migration of "iso_create" audit events to scheduled products is ongoing. This might take a while.');

    while (my $event = $audit_events->next) {
        my $event_id = $event->id;
        my $settings;
        try {
            $settings = decode_json($event->event_data);
        };
        if (!$settings) {
            log_warning(
                "Unable to read settings from 'iso_create' audit event with ID $event_id. Skipping its migration.");
            next;
        }

        my $scheduled_product = $scheduled_products->create(
            {
                distri => $settings->{DISTRI} // '',
                version => $settings->{VERSION} // '',
                flavor => $settings->{FLAVOR} // '',
                arch => $settings->{ARCH} // '',
                build => $settings->{BUILD} // '',
                iso => $settings->{ISO} // '',
                status => OpenQA::Schema::Result::ScheduledProducts::SCHEDULED,
                settings => $settings,
                user_id => $event->user_id,
                t_created => $event->t_created,
            });

        # update the event_data so it only contains the product ID and the data is not duplicated
        $event->update({event_data => encode_json({scheduled_product_id => $scheduled_product->id})});
    }
  }
