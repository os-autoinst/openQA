# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::ResultSet::Workers;
use Mojo::Base 'DBIx::Class::ResultSet', -signatures;

use OpenQA::WorkerReservation qw(RESERVATION_PROPERTIES reservation_active);

# maps the id of every worker holding a non-expired reservation to 1, using a single query so that
# callers filtering many workers do not have to query the properties of each of them individually
sub reserved_worker_ids ($self) {
    my $properties = $self->result_source->schema->resultset('WorkerProperties')
      ->search({key => {-in => [RESERVATION_PROPERTIES]}}, {columns => [qw(worker_id key value)]});
    my (%owner, %expires);
    while (my $property = $properties->next) {
        my $key = $property->key;
        $owner{$property->worker_id} = $property->value if $key eq 'RESERVED_BY_ID';
        $expires{$property->worker_id} = $property->value if $key eq 'RESERVED_T_EXPIRES';
    }
    return {map { $_ => 1 } grep { reservation_active($owner{$_}, $expires{$_}) } keys %owner};
}

sub stats ($self) {
    my $total = $self->count;
    my @online = grep { !$_->dead } $self->all;
    my $reserved = $self->reserved_worker_ids;

    return {
        total => $total,
        total_online => scalar @online,
        free_active_workers => scalar(grep { $_->is_free && !$reserved->{$_->id} } @online),
        free_broken_workers => scalar(grep { !$_->job_id && defined $_->error } @online),
        busy_workers => scalar(grep { $_->job_id } @online),
        reserved_workers => scalar(grep { $_->is_free && $reserved->{$_->id} } @online),
    };
}

1;
