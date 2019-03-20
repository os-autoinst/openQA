# Copyright (C) 2014-2019 SUSE LLC
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

package OpenQA::WebSockets::Server;
use Mojo::Base 'Mojolicious';

use Mojo::Server::Daemon;
use Try::Tiny;
use OpenQA::IPC;
use OpenQA::Utils qw(log_debug log_warning log_info);
use OpenQA::Schema;
use OpenQA::Setup;
use db_profiler;
use OpenQA::Schema::Result::Workers ();
use OpenQA::Constants 'WORKERS_CHECKER_THRESHOLD';

# id->worker mapping
our $WORKERS = {};

# Will be filled out from worker status messages
our $WORKER_STATUS = {};

# Mojolicious startup
sub setup {
    my $self = shift;

    $self->helper(log_name => sub { return 'websockets' });
    $self->helper(schema   => sub { return OpenQA::Schema->singleton });
    $self->defaults(appname => 'openQA Websocket Server');
    $self->mode('production');

    OpenQA::Setup::read_config($self);
    OpenQA::Setup::setup_log($self);

    push @{$self->plugins->namespaces}, 'OpenQA::WebAPI::Plugin';

    # Assetpack is required to render layouts pages
    $self->plugin(AssetPack => {pipes => [qw(Sass Css JavaScript Fetch OpenQA::WebAPI::AssetPipe Combine)]});
    $self->plugin('Helpers');
    $self->asset->process;

    my $r = $self->routes;
    $self->routes->namespaces(['OpenQA::WebSockets::Controller']);
    my $ca = $r->under('/')->to('Auth#check');
    $ca->websocket('/ws/<workerid:num>')->to('Worker#ws');

    # no cookies for worker, no secrets to protect
    $self->secrets(['nosecretshere']);

    # start worker checker - check workers each 2 minutes
    Mojo::IOLoop->recurring(120 => \&_workers_checker);

    Mojo::IOLoop->recurring(
        380 => sub {
            log_debug('Resetting worker status table');
            $WORKER_STATUS = {};
        });

    return Mojo::Server::Daemon->new(app => $self);
}

sub ws_is_worker_connected {
    my ($workerid) = @_;
    return ($WORKERS->{$workerid} && $WORKERS->{$workerid}->{socket} ? 1 : 0);
}

sub ws_send {
    my ($workerid, $msg, $jobid, $retry) = @_;
    return unless ($workerid && $msg && $WORKERS->{$workerid});
    $jobid ||= '';
    my $res;
    my $tx = $WORKERS->{$workerid}->{socket};
    if ($tx) {
        $res = $tx->send({json => {type => $msg, jobid => $jobid}});
    }
    unless ($res && !$res->error) {
        $retry ||= 0;
        if ($retry < 3) {
            Mojo::IOLoop->timer(2 => sub { ws_send($workerid, $msg, $jobid, ++$retry); });
        }
        else {
            log_debug("Unable to send command \"$msg\" to worker $workerid");
        }
    }
}

sub ws_send_job {
    my ($job) = @_;
    my $result = {state => {msg_sent => 0}};

    unless (ref($job) eq 'HASH' && exists $job->{assigned_worker_id}) {
        $result->{state}->{error} = "No workerid assigned";
        return $result;
    }

    unless ($WORKERS->{$job->{assigned_worker_id}}) {
        $result->{state}->{error}
          = "Worker " . $job->{assigned_worker_id} . " doesn't have established a ws connection";
        return $result;
    }

    my $res;
    my $tx = $WORKERS->{$job->{assigned_worker_id}}->{socket};
    if ($tx) {
        $res = $tx->send({json => {type => 'grab_job', job => $job}});
    }
    unless ($res && !$res->error) {
        # Since it is used by scheduler, it's fine to let it fail,
        # will be rescheduled on next round
        log_debug("Unable to allocate job to worker $job->{assigned_worker_id}");
        $result->{state}->{error} = "Sending $job->{id} thru WebSockets to $job->{assigned_worker_id} failed miserably";
        $result->{state}->{res}   = $res;
        return $result;
    }
    else {
        log_debug("message sent to $job->{assigned_worker_id} for job $job->{id}");
        $result->{state}->{msg_sent} = 1;
    }
    return $result;
}

# consider ws_send_all as broadcast and don't wait for confirmation
sub ws_send_all {
    my ($msg) = @_;
    for my $tx (values %$WORKERS) {
        if ($tx->{socket}) {
            $tx->{socket}->send({json => {type => $msg}});
        }
    }
}

sub _get_stale_worker_jobs {
    my ($threshold) = @_;

    my $schema = OpenQA::Schema->singleton;

    # grab the workers we've seen lately
    my @ok_workers;
    for my $worker (values %$WORKERS) {
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

sub _is_job_considered_dead {
    my ($job) = @_;

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

# Check if worker with job has been updated recently; if not, assume it
# got stuck somehow and duplicate or incomplete the job
sub _workers_checker {
    my $schema = OpenQA::Schema->singleton;
    try {
        $schema->txn_do(
            sub {
                my $stale_jobs = _get_stale_worker_jobs(WORKERS_CHECKER_THRESHOLD);
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

1;
