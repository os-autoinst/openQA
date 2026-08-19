# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::ResultSet::Workers;
use Mojo::Base 'DBIx::Class::ResultSet', -signatures;

use OpenQA::WorkerReservation qw(RESERVATION_PROPERTIES reservation_active reservation_info);

# maps the id of every worker holding a non-expired reservation to a hash with reservation properties,
# using a single query so that callers filtering many workers do not have to query the properties of each of them individually
sub active_reservations ($self) {
    my $properties = $self->result_source->schema->resultset('WorkerProperties')
      ->search({key => {-in => [RESERVATION_PROPERTIES]}}, {columns => [qw(worker_id key value)]});
    my %worker_props;
    while (my $property = $properties->next) {
        $worker_props{$property->worker_id}->{$property->key} = $property->value;
    }

    my %reservations;
    for my $worker_id (keys %worker_props) {
        my $props = $worker_props{$worker_id};
        if (reservation_active($props->{RESERVED_BY_ID}, $props->{RESERVED_T_EXPIRES})) {
            $reservations{$worker_id} = reservation_info($props);
        }
    }
    return \%reservations;
}

sub stats ($self) {
    my $total = $self->count;
    my @online = grep { !$_->dead } $self->all;
    my $reserved = $self->active_reservations;
    my $is_free = sub ($worker) { !$worker->job_id && !defined $worker->error };

    return {
        total => $total,
        total_online => scalar @online,
        free_active_workers => scalar(grep { $is_free->($_) && !$reserved->{$_->id} } @online),
        free_broken_workers => scalar(grep { !$_->job_id && defined $_->error } @online),
        busy_workers => scalar(grep { $_->job_id } @online),
        reserved_workers => scalar(grep { $is_free->($_) && $reserved->{$_->id} } @online),
    };
}

1;
