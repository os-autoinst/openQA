# Copyright (C) 2014 SUSE Linux Products GmbH
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

use strict;
use warnings;

use OpenQA::Scheduler ();
use OpenQA::Utils qw/log_debug/;

require Exporter;
our (@ISA, @EXPORT, @EXPORT_OK);

@ISA = qw/Exporter/;
@EXPORT = qw/ws_send ws_send_all/;
@EXPORT_OK = qw/ws_create ws_is_worker_connected ws_add_worker ws_remove_worker/;

# worker->websockets mapping
my $worker_sockets = {};

# internal helpers prototypes
sub _message;
sub _get_worker;

# websockets helper functions
sub ws_add_worker {
    my ($workerid, $ws_connection) = @_;
    $worker_sockets->{$workerid} = $ws_connection;
}

sub ws_remove_worker {
    my ($workerid) = @_;
    delete $worker_sockets->{$workerid};
}

sub ws_send {
    my ($workerid, $msg, $jobid, $retry) = @_;
    return unless ($workerid && $msg);
    $jobid ||= '';
    my $res;
    my $tx = $worker_sockets->{$workerid};
    if ($tx) {
        $res = $tx->send({json => { type => $msg, jobid => $jobid }});
    }
    unless ($res && $res->success) {
        $retry ||= 0;
        if ($retry < 3) {
            Mojo::IOLoop->timer(2 => sub{ws_send($workerid, $msg, $jobid, ++$retry);});
        }
        else {
            log_debug("Unable to send command \"$msg\" to worker $workerid");
        }
    }
}

sub ws_send_all {
    my ($msg) = @_;
    foreach my $workerid (keys(%$worker_sockets)) {
        ws_send($workerid, $msg);
    }
}

sub ws_create {
    my ($workerid, $ws) = @_;
    OpenQA::Scheduler::_validate_workerid($workerid);
    # upgrade connection to websocket by subscribing to events
    $ws->on(json => \&_message);
    $ws->on(finish  => \&_finish);
    ws_add_worker($workerid, $ws->tx->max_websocket_size(10485760));
}

sub ws_is_worker_connected {
    my ($worker) = @_;
    defined $worker_sockets->{$worker->id} ? 1 : 0;
}

# internal helpers
sub _get_worker {
    my ($tx) = @_;
    my $connection1 = $tx->connection;
    my $ret;
    while ( my ($id, $stored_tx) = each %$worker_sockets ) {
        if ($stored_tx->connection eq $tx->connection) {
            $ret = $id;
        }
    }
    # reset hash iterator
    keys(%$worker_sockets);
    return $ret;
}

sub _finish {
    my ($ws, $code, $reason) = @_;
    return unless ($ws);

    my $workerid = _get_worker($ws->tx);
    unless ($workerid) {
        $ws->app->log->error('Worker ID not found for given connection during connection close');
        return;
    }
    $ws->app->log->debug("Worker $workerid websocket connection closed - $code\n");
    ws_remove_worker($workerid);
}

sub _message {
    my ($ws, $json) = @_;
    my $workerid = _get_worker($ws->tx);
    unless ($workerid) {
        $ws->app->log->warn("A message received from unknown worker connection");
        return;
    }
    unless (ref($json) eq 'HASH') {
        use Data::Dumper;
        $ws->app->log->error(sprintf('Received unexpected WS message "%s from worker %u', Dumper($json), $workerid));
        return;
    }

    my $worker = OpenQA::Scheduler::_validate_workerid($workerid);
    $worker->seen();
    if ($json->{'type'} eq 'ok') {
        $ws->tx->send({json => {type => 'ok'}});
    }
    elsif ($json->{'type'} eq 'status') {
        # handle job status update through web socket
        my $jobid = $json->{'jobid'};
        my $status = $json->{'data'};
        my $job = $ws->app->schema->resultset("Jobs")->find($jobid);
        return $ws->tx->send(json => {result => 'nack'}) unless $job;
        my $ret = $job->update_status($status);
        $ws->tx->send({json => $ret});
    }
    else{
        $ws->app->log->error(sprintf('Received unknown message type "%s" from worker %u', $json->{'type'}, $workerid));
    }
}


1;
