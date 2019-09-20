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
use OpenQA::Setup;
use OpenQA::Utils qw(log_debug log_warning log_info);
use OpenQA::WebSockets::Model::Status;

our $RUNNING;

sub startup {
    my $self = shift;

    $self->_setup if $RUNNING;

    $self->defaults(appname => 'openQA Websocket Server');

    # no cookies for worker, no secrets to protect
    $self->secrets(['nosecretshere']);
    $self->config->{no_localhost_auth} ||= 1;

    push @{$self->plugins->namespaces}, 'OpenQA::WebSockets::Plugin';
    $self->plugin('Helpers');
    $self->plugin('OpenQA::Shared::Plugin::Helpers');

    my $r = $self->routes;
    $r->namespaces(['OpenQA::WebSockets::Controller', 'OpenQA::Shared::Controller']);
    my $ca = $r->under('/')->to('Auth#check');
    $ca->get('/' => {json => {name => $self->defaults('appname')}});
    my $api = $ca->any('/api');
    $api->get('/is_worker_connected/<worker_id:num>')->to('API#is_worker_connected');
    $api->post('/send_job')->to('API#send_job');
    $api->post('/send_jobs')->to('API#send_jobs');
    $api->post('/send_msg')->to('API#send_msg');
    $ca->websocket('/ws/<workerid:num>')->to('Worker#ws');
    $r->any('/*whatever' => {whatever => ''})->to(status => 404, text => 'Not found');

    OpenQA::Setup::setup_plain_exception_handler($self);
}

sub run {
    local $RUNNING = 1;
    __PACKAGE__->new->start;
}

sub ws_send {
    my ($workerid, $msg, $jobid, $retry) = @_;

    return undef unless $workerid && $msg;
    return undef unless my $worker = OpenQA::WebSockets::Model::Status->singleton->workers->{$workerid};

    $jobid ||= '';
    my $res;
    my $tx = $worker->{tx};
    if ($tx && !$tx->is_finished) {
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
    return $res;
}

sub ws_send_job {
    my ($job_info, $message) = @_;
    my $result = {state => {msg_sent => 0}};

    unless (ref($job_info) eq 'HASH' && exists $job_info->{assigned_worker_id}) {
        $result->{state}->{error} = "No workerid assigned";
        return $result;
    }

    my $worker_id = $job_info->{assigned_worker_id};
    my $worker    = OpenQA::WebSockets::Model::Status->singleton->workers->{$worker_id};
    if (!$worker) {
        $result->{state}->{error} = "Worker $worker_id doesn't have established a ws connection";
        return $result;
    }

    my $res;
    my $tx = $worker->{tx};
    if ($tx && !$tx->is_finished) {
        $res = $tx->send({json => $message});
    }
    my $id_string = ref($job_info->{ids}) eq 'ARRAY' ? join(', ', @{$job_info->{ids}}) : $job_info->{id} // '?';
    unless ($res && !$res->error) {
        # Since it is used by scheduler, it's fine to let it fail,
        # will be rescheduled on next round
        log_debug("Unable to allocate job to worker $worker_id");
        $result->{state}->{error} = "Sending $id_string thru WebSockets to $worker_id failed miserably";
        $result->{state}->{res}   = $res;
        return $result;
    }
    else {
        log_debug("message sent to $worker_id for job $id_string");
        $result->{state}->{msg_sent} = 1;
    }
    return $result;
}

sub _setup {
    my $self = shift;

    OpenQA::Setup::read_config($self);
    OpenQA::Setup::setup_log($self);

    # start worker checker - check workers each 2 minutes
    Mojo::IOLoop->recurring(120 => sub { $self->status->workers_checker });

    Mojo::IOLoop->recurring(
        380 => sub {
            log_debug('Resetting worker status table');
            $self->status->worker_status({});
        });
}

1;
