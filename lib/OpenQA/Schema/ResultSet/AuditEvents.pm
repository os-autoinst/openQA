# Copyright 2019-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::ResultSet::AuditEvents;

use strict;
use warnings;

use Time::Piece;
use Time::Seconds;
use Time::ParseDate;
use OpenQA::App;
use OpenQA::Log 'log_warning';
use OpenQA::Utils;

use base 'DBIx::Class::ResultSet';

my %patterns_for_event_categories = (
    startup => 'startup',
    jobgroup => 'jobgroup_%',
    jobtemplate => 'jobtemplate_%',
    table => 'table_%',
    iso => 'iso_%',
    user => 'user_%',
    asset => 'asset_%',
    needle => 'needle_%',
);

sub delete_entries_exceeding_storage_duration {
    my ($self, %options) = @_;

    my @event_type_globs;
    my @queries;
    my $other_time_constraint;

    # make queries for event types
    my $storage_durations = OpenQA::App->singleton->config->{'audit/storage_duration'};
    for my $event_category (keys %$storage_durations) {
        my $duration_in_days = $storage_durations->{$event_category};
        next unless $duration_in_days;

        # parse time constraint
        my $time_constraint = parsedate("$duration_in_days days ago", PREFER_PAST => 1, DATE_REQUIRED => 1)
          or
          log_warning("Ignoring invalid storage duration '$duration_in_days' for audit event type '$event_category'.")
          and next;
        $time_constraint = localtime($time_constraint)->ymd;

        if ($event_category eq 'other') {
            $other_time_constraint = $time_constraint;
            next;
        }

        my $event_type_pattern = $patterns_for_event_categories{$event_category}
          or log_warning("Ignoring unknown event type '$event_category'.")
          and next;
        push(
            @queries,
            {
                event => {-like => $event_type_pattern},
                t_created => {'<' => $time_constraint},
            });
    }

    # make query for events *not* matching any of the specified event types
    # note: DBIx always adds an additional 'AND'. Making the query manually to workaround this issue.
    my @category_patterns = values %patterns_for_event_categories;
    my $delete_other_query
      = $other_time_constraint
      ? $self->result_source->schema->storage->dbh->prepare('DELETE FROM audit_events WHERE t_created < ? AND '
          . join(' AND ', map { 'event NOT LIKE ?' } @category_patterns))
      : undef;

    # perform queries
    $self->search($_)->delete for @queries;
    $delete_other_query->execute($other_time_constraint, @category_patterns) if ($delete_other_query);
}

1;
