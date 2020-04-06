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
# with this program; if not, see <http://www.gnu.org/licenses/>.

use strict;
use DBIx::Class::DeploymentHandler;
use OpenQA::Schema;
use OpenQA::Log 'log_info';
use OpenQA::Utils;

sub {
    my ($schema) = @_;

    log_info('Migrating machine separator in dependency settings form ":" to "@".');

    my @affected_keys   = (qw(START_AFTER_TEST START_DIRECTLY_AFTER_TEST PARALLEL_WITH));
    my @affected_tables = (qw(JobSettings JobTemplateSettings MachineSettings ProductSettings TestSuiteSettings));
    my $considered_rows = 0;
    my $changed_rows    = 0;
    for my $table_name (@affected_tables) {
        log_info(" - considering $table_name table");

        my $table         = $schema->resultset($table_name);
        my $affected_rows = $table->search({key => {-in => \@affected_keys}});
        while (my $row = $affected_rows->next) {
            my $current_value          = $row->value;
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
