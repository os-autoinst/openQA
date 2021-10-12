#!/usr/bin/env perl

# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use strict;
use DBIx::Class::DeploymentHandler;
use OpenQA::Schema;
use OpenQA::Log 'log_info';
use OpenQA::Utils;

sub {
    my ($schema) = @_;

    log_info('Migrating machine separator in dependency settings form ":" to "@".');

    my @affected_keys = (qw(START_AFTER_TEST START_DIRECTLY_AFTER_TEST PARALLEL_WITH));
    my @affected_tables = (qw(JobSettings JobTemplateSettings MachineSettings ProductSettings TestSuiteSettings));
    my $considered_rows = 0;
    my $changed_rows = 0;
    for my $table_name (@affected_tables) {
        log_info(" - considering $table_name table");

        my $table = $schema->resultset($table_name);
        my $affected_rows = $table->search({key => {-in => \@affected_keys}});
        while (my $row = $affected_rows->next) {
            my $current_value = $row->value;
            my $value_needs_conversion = 0;
            $considered_rows += 1;

            # split value in consistency with OpenQA::Schema::Result::ScheduledProducts::_parse_dep_variable
            my @new_parts;
            for my $part (split(/\s*,\s*/, $current_value)) {
                # replace last ":" separator of each part with "@" if present; otherwise keep the part as-is
                if ($part =~ /^(.+):([^:]+)$/) {
                    push(@new_parts, "$1\@$2");
                    $value_needs_conversion = 1;
                }
                else {
                    push(@new_parts, $part);
                }
            }

            next unless $value_needs_conversion;
            my $new_value = join(',', @new_parts);
            log_info("   $current_value => $new_value");
            $row->update({value => $new_value});
            $changed_rows += 1;
        }
    }

    log_info(" - migration done; considered rows: $considered_rows; changed rows: $changed_rows");
  }
