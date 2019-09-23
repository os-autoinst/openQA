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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package OpenQA::WebSockets::Model::Status;
use Mojo::Base -base;

use OpenQA::Schema;
use OpenQA::Schema::Result::Workers ();
use OpenQA::Utils qw(log_debug log_warning log_info);
use OpenQA::Constants 'WORKERS_CHECKER_THRESHOLD';
use OpenQA::Jobs::Constants;
use OpenQA::Scheduler::Client;
use DateTime;
use Try::Tiny;

has [qw(workers worker_by_transaction worker_status)] => sub { {} };

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
            id        => $worker_id,
            db        => $db,
            tx        => undef,
            last_seen => time(),
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

sub is_worker_connected {
    my ($self, $worker_id) = @_;

    return 0 unless my $worker = $self->workers->{$worker_id};
    return 0 unless my $tx     = $worker->{tx};
    return !$tx->is_finished;
}

sub get_stale_worker_jobs {
    my ($self, $threshold) = @_;

    my $schema  = OpenQA::Schema->singleton;
    my $workers = $self->workers;

    # grab the workers we've seen lately
    my @ok_workers;
    for my $worker (values %$workers) {
        if (time - $worker->{last_seen} <= $threshold) {
            push(@ok_workers, $worker->{id});
        }
        else {
            log_debug(sprintf("Worker %s not seen since %d seconds", $worker->{db}->name, time - $worker->{last_seen}));
        }
    }
    my $dtf = $schema->storage->datetime_parser;
    my $dt  = DateTime->from_epoch(epoch => time() - $threshold, time_zone => 'UTC');

    my %cond = (
        state              => [OpenQA::Jobs::Constants::EXECUTION_STATES],
        'worker.t_updated' => {'<' => $dtf->format_datetime($dt)},
        'worker.id'        => {-not_in => [sort @ok_workers]});
    my %attrs = (join => 'worker', order_by => 'worker.id desc');

    return $schema->resultset("Jobs")->search(\%cond, \%attrs);
}

# Check if worker with job has been updated recently; if not, assume it
# got stuck somehow and duplicate or incomplete the job
sub workers_checker {
    my ($self, $callback) = @_;

    my $dead_jobs;
    try {
        $dead_jobs = $self->get_stale_worker_jobs(WORKERS_CHECKER_THRESHOLD);
    }
    catch {
        log_info("Failed dead job detection: $_");
    };
    return undef unless $dead_jobs;

    my @job_ids = map { $_->id } $dead_jobs->all;
    return undef unless @job_ids;
    OpenQA::Scheduler::Client->singleton->report_stale_jobs(\@job_ids, $callback);
}

1;
