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

package OpenQA::WebSockets;
use Mojo::Base 'Mojolicious';

use Mojo::Server::Daemon;
use OpenQA::IPC;
use OpenQA::Setup;
use OpenQA::Utils qw(log_debug log_warning log_info);
use OpenQA::WebSockets::Model::Status;
use db_profiler;

sub run { __PACKAGE__->new->setup->run }

sub startup {
    my $self = shift;

    $self->defaults(appname => 'openQA Websocket Server');
    $self->mode('production');

    # no cookies for worker, no secrets to protect
    $self->secrets(['nosecretshere']);

    # Assetpack is required to render layouts pages
    push @{$self->plugins->namespaces}, 'OpenQA::WebSockets::Plugin';
    $self->plugin(AssetPack => {pipes => [qw(Sass Css JavaScript Fetch OpenQA::WebAPI::AssetPipe Combine)]});
    $self->plugin('Helpers');
    $self->plugin('OpenQA::WebAPI::Plugin::Helpers');
    $self->asset->process;

    my $r = $self->routes;
    $r->namespaces(['OpenQA::WebSockets::Controller']);
    my $ca = $r->under('/')->to('Auth#check');
    $ca->get('/' => {json => {name => $self->defaults('appname')}});
    my $api = $ca->any('/api');
    $api->get('/is_worker_connected/<worker_id:num>')->to('API#is_worker_connected');
    $api->post('/send_job')->to('API#send_job');
    $api->post('/send_msg')->to('API#send_msg');
    $ca->websocket('/ws/<workerid:num>')->to('Worker#ws');
    $r->any('/*whatever' => {whatever => ''})->to(status => 404, text => 'Not found');
}

sub setup {
    my $self = shift;

    OpenQA::Setup::read_config($self);
    OpenQA::Setup::setup_log($self);

    # start worker checker - check workers each 2 minutes
    Mojo::IOLoop->recurring(120 => sub { $self->workers_checker });

    Mojo::IOLoop->recurring(
        380 => sub {
            log_debug('Resetting worker status table');
            $self->status->worker_status({});
        });

    return Mojo::Server::Daemon->new(app => $self);
}

sub ws_is_worker_connected {
    my ($workerid) = @_;
    my $workers = OpenQA::WebSockets::Model::Status->singleton->workers;
    return ($workers->{$workerid} && $workers->{$workerid}->{socket} ? 1 : 0);
}

sub ws_send {
    my ($workerid, $msg, $jobid, $retry) = @_;

    my $workers = OpenQA::WebSockets::Model::Status->singleton->workers;
    return unless ($workerid && $msg && $workers->{$workerid});
    $jobid ||= '';
    my $res;
    my $tx = $workers->{$workerid}->{socket};
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

    my $workers = OpenQA::WebSockets::Model::Status->singleton->workers;
    unless ($workers->{$job->{assigned_worker_id}}) {
        $result->{state}->{error}
          = "Worker " . $job->{assigned_worker_id} . " doesn't have established a ws connection";
        return $result;
    }

    my $res;
    my $tx = $workers->{$job->{assigned_worker_id}}->{socket};
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

1;
