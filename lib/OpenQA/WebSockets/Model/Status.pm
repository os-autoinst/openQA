# Copyright (C) 2019 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

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
    my $worker  = $workers->{$worker_id};
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
