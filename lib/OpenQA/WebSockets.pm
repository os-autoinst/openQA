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

use Scheduler ();

require Exporter;
our (@ISA, @EXPORT, @EXPORT_OK);

@ISA = qw/Exporter/;
@EXPORT = qw/ws_add_worker ws_remove_worker ws_send/;
@EXPORT_OK = qw/ws_create/;

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
    my ($workerid, $msg) = @_;
    my $tx = $worker_sockets->{$workerid};
    return unless $tx;
    my $res = $tx->send($msg);
    if ($res->success) {
        return 1;
    }
    return;
}

sub ws_create {
    my ($workerid, $ws) = @_;
    # upgrade connection to websocket by subscribing to events
    $ws->on(message => \&_message);
    $ws->on(finish  => \&_finish);
    ws_add_worker($workerid, $ws->tx);
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
        $ws->app->log->warn('Worker ID not found for given connection during connection close');
        return;
    }
    $ws->app->log->debug("Worker $workerid websocket connection closed - $code\n");
    ws_remove_worker($workerid);
}

sub _message {
    my ($ws, $msg) = @_;
    my $workerid = _get_worker($ws->tx);
    unless ($workerid) {
        $ws->app->log->warn("A message received from unknown worker connection");
        return;
    }
    Scheduler::_validate_workerid($workerid);
    Scheduler::_seen_worker($workerid);
    if ($msg eq 'ok') {
        $ws->tx->send('ok');
    }
    else{
        print STDERR "Received unexpected WS message \"$msg\" from worker \"$workerid\"";
    }
}


1;
