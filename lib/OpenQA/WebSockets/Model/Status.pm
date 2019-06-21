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
use DateTime;
use Try::Tiny;

has ['workers', 'worker_status'] => sub { {} };

sub singleton { state $status ||= __PACKAGE__->new }

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
    my $self = shift;

    my $schema = OpenQA::Schema->singleton;
    try {
        $schema->txn_do(
            sub {
                my $stale_jobs = $self->get_stale_worker_jobs(WORKERS_CHECKER_THRESHOLD);
                for my $job ($stale_jobs->all) {
                    next unless _is_job_considered_dead($job);

                    $job->done(result => OpenQA::Jobs::Constants::INCOMPLETE);
                    # XXX: auto_duplicate was killing ws server in production
                    my $res = $job->auto_duplicate;
                    if ($res) {
                        log_warning(sprintf('dead job %d aborted and duplicated %d', $job->id, $res->id));
                    }
                    else {
                        log_warning(sprintf('dead job %d aborted as incomplete', $job->id));
                    }
                }
            });
    }
    catch {
        log_info("Failed dead job detection : $_");
    };
}

sub _is_job_considered_dead {
    my $job = shift;

    # much bigger timeout for uploading jobs; while uploading files,
    # worker process is blocked and cannot send status updates
    if ($job->state eq OpenQA::Jobs::Constants::UPLOADING) {
        my $delta = DateTime->now()->epoch() - $job->worker->t_updated->epoch();
        log_debug("uploading worker not updated for $delta seconds " . $job->id);
        return ($delta > 1000);
    }

    log_debug(
        "job considered dead: " . $job->id . " worker " . $job->worker->id . " not seen. In state " . $job->state);
    # default timeout for the rest
    return 1;
}

1;
