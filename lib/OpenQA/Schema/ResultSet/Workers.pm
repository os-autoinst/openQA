# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::ResultSet::Workers;
use Mojo::Base 'DBIx::Class::ResultSet', -signatures;

sub stats ($self) {
    my $total = $self->count;
    my $total_online = grep { !$_->dead } $self->all();
    my $free_active_workers = grep { !$_->dead } $self->search({job_id => undef, error => undef})->all();
    my $free_broken_workers = grep { !$_->dead } $self->search({job_id => undef, error => {'!=' => undef}})->all();
    my $busy_workers = grep { !$_->dead } $self->search({job_id => {'!=' => undef}})->all();

    return {
        total => $total,
        total_online => $total_online,
        free_active_workers => $free_active_workers,
        free_broken_workers => $free_broken_workers,
        busy_workers => $busy_workers,
    };
}

1;
