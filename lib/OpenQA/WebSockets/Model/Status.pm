# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebSockets::Model::Status;
use Mojo::Base -base, -signatures;

use DateTime;
use Time::Seconds;
use OpenQA::Schema;
use OpenQA::Schema::Result::Workers ();
use OpenQA::Jobs::Constants;
use OpenQA::Log qw(log_debug);

has [qw(workers worker_by_transaction)] => sub { {} };

sub singleton { state $status ||= __PACKAGE__->new }

sub _is_limit_exceeded ($self, $worker_db, $worker_is_new, $controller) {
    my $misc_limits = $controller->app->config->{misc_limits};
    my $limit = $misc_limits->{max_online_workers};
    return 0 if !defined($limit) || $limit > keys %{$self->worker_by_transaction};
    $worker_db->discard_changes unless $worker_is_new;
    return 0 if defined($worker_db->job_id);    # allow workers that work on a job
    $worker_db->update({t_seen => undef, error => 'limited at ' . DateTime->now(time_zone => 'UTC')});
    $controller->res->headers->append('Retry-After' => $misc_limits->{worker_limit_retry_delay});
    $controller->render(text => 'Limit of worker connections exceeded', status => 429);
    return 1;
}

sub add_worker_connection ($self, $worker_id, $controller) {

    # add new worker entry if no exists yet
    my $workers = $self->workers;
    my $worker = $workers->{$worker_id};
    my $worker_is_new = !defined $worker;
    if ($worker_is_new) {
        my $db = OpenQA::Schema->singleton->resultset('Workers')->find($worker_id);
        if (!$db) {
            $controller->render(text => 'Unknown worker', status => 400);
            return undef;
        }
        $worker = $workers->{$worker_id} = {
            id => $worker_id,
            db => $db,
            tx => undef,
        };
    }

    my $current_tx = $worker->{tx};
    if ($current_tx && !$current_tx->is_finished) {
        log_debug "Finishing current connection of worker $worker_id before accepting new one";
        $current_tx->finish(1008 => 'only one connection per worker allowed, finishing old one in favor of new one');
    }
    else {
        return undef if $self->_is_limit_exceeded($worker->{db}, $worker_is_new, $controller);
    }

    my $new_tx = $controller->tx;
    $self->worker_by_transaction->{$new_tx} = $worker;

    # assign the transaction to have always the most recent web socket connection for a certain worker
    # available
    $worker->{tx} = $new_tx;

    return $worker;
}

sub remove_worker_connection {
    my ($self, $transaction) = @_;
    return delete $self->worker_by_transaction->{$transaction};
}

1;
