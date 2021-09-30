# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebSockets::Model::Status;
use Mojo::Base -base;

use OpenQA::Schema;
use OpenQA::Schema::Result::Workers ();
use OpenQA::Jobs::Constants;

has [qw(workers worker_by_transaction)] => sub { {} };

sub singleton { state $status ||= __PACKAGE__->new }

sub add_worker_connection {
    my ($self, $worker_id, $transaction) = @_;

    # add new worker entry if no exists yet
    my $workers = $self->workers;
    my $worker = $workers->{$worker_id};
    if (!defined $worker) {
        my $schema = OpenQA::Schema->singleton;
        return undef unless my $db = $schema->resultset('Workers')->find($worker_id);
        $worker = $workers->{$worker_id} = {
            id => $worker_id,
            db => $db,
            tx => undef,
        };
    }

    $self->worker_by_transaction->{$transaction} = $worker;

    # assign the transaction to have always the most recent web socket connection for a certain worker
    # available
    $worker->{tx} = $transaction;

    return $worker;
}

sub remove_worker_connection {
    my ($self, $transaction) = @_;
    return delete $self->worker_by_transaction->{$transaction};
}

1;
