# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::ResultSet::Workers;
use Mojo::Base 'DBIx::Class::ResultSet', -signatures;

use OpenQA::WorkerReservation qw(RESERVATION_PROPERTIES reservation_active reservation_info reservation_error);

# maps the id of every worker holding a non-expired reservation to a hash with reservation properties,
# using a single query so that callers filtering many workers do not have to query the properties of each of them individually
sub active_reservations ($self) {
    my $properties = $self->result_source->schema->resultset('WorkerProperties')
      ->search({key => {-in => [RESERVATION_PROPERTIES]}}, {columns => [qw(worker_id key value)]});
    my %worker_props;
    while (my $property = $properties->next) {
        $worker_props{$property->worker_id}->{$property->key} = $property->value;
    }

    return {
        map { $_ => reservation_info($worker_props{$_}) }
        grep { reservation_active($worker_props{$_}{RESERVED_BY_ID}, $worker_props{$_}{RESERVED_T_EXPIRES}) }
          keys %worker_props
    };
}

sub stats ($self) {
    my $total = $self->count;
    my @online = grep { !$_->dead } $self->all;
    my $reserved = $self->active_reservations;

    return {
        total => $total,
        total_online => scalar @online,
        free_active_workers => scalar(grep { $_->is_free && !$reserved->{$_->id} } @online),
        free_broken_workers => scalar(grep { !$_->job_id && defined $_->error } @online),
        busy_workers => scalar(grep { $_->job_id } @online),
        reserved_workers => scalar(grep { $_->is_free && $reserved->{$_->id} } @online),
    };
}

sub reserve_host ($self, $host, $user, %args) {
    my $is_admin = $user->is_admin;
    die reservation_error(forbidden => 'Insufficient permissions to reserve a worker')
      unless $is_admin || $user->is_operator;

    my @workers = $self->search({host => $host})->all;
    die reservation_error(not_found => "Worker host '$host' not found") unless @workers;

    $self->result_source->schema->txn_do(
        sub {
            my @conflicts;
            for my $worker (@workers) {
                if ($worker->is_reserved) {
                    my $res_info = $worker->_reservation_properties;
                    my $owner_id = $res_info->{RESERVED_BY_ID};
                    if ($owner_id != $user->id) {
                        if (!($args{force} && $is_admin)) {
                            push @conflicts, $worker->name;
                        }
                    }
                }
            }
            if (@conflicts) {
                die reservation_error(
                    conflict => 'Worker host matches instances already reserved by: ' . join ', ',
                    @conflicts
                );
            }

            for my $worker (@workers) {
                $worker->reserve($user, $args{comment}, $args{duration}, $args{force}, $args{worker_class}, 'host');
            }
        });

    return \@workers;
}

sub release_host ($self, $host, $user, %args) {
    my $is_admin = $user->is_admin;
    die reservation_error(forbidden => 'Insufficient permissions to release a worker')
      unless $is_admin || $user->is_operator;

    my @workers = $self->search({host => $host})->all;
    die reservation_error(not_found => "Worker host '$host' not found") unless @workers;

    $self->result_source->schema->txn_do(
        sub {
            my @foreign_owned;
            my @reserved;
            for my $worker (@workers) {
                if ($worker->is_reserved) {
                    push @reserved, $worker;
                    my $res_info = $worker->_reservation_properties;
                    my $owner_id = $res_info->{RESERVED_BY_ID};
                    if ($owner_id != $user->id && !$is_admin) {
                        push @foreign_owned, $worker->name;
                    }
                }
            }

            if (@foreign_owned) {
                die reservation_error(
                    forbidden => 'Insufficient permissions to release reservation owned by other users on: '
                      . join ', ',
                    @foreign_owned
                );
            }

            for my $worker (@reserved) {
                $worker->release($user);
            }
        });

    return \@workers;
}

1;
