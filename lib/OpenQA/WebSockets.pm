# Copyright (C) 2015 SUSE LLC
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
use Mojolicious::Lite;
use Mojo::Util 'hmac_sha1_sum';

use OpenQA::IPC;
use OpenQA::Utils qw/log_debug/;
use OpenQA::Schema::Schema;

use parent qw/Exporter/;
our (@EXPORT, @EXPORT_OK);

@EXPORT    = qw/ws_send ws_send_all/;
@EXPORT_OK = qw/ws_create ws_is_worker_connected ws_add_worker ws_remove_worker/;

# worker->websockets mapping
my $worker_sockets = {};
my $plugins;

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
        $res = $tx->send({json => {type => $msg, jobid => $jobid}});
    }
    unless ($res && $res->success) {
        $retry ||= 0;
        if ($retry < 3) {
            Mojo::IOLoop->timer(2 => sub { ws_send($workerid, $msg, $jobid, ++$retry); });
        }
        else {
            log_debug("Unable to send command \"$msg\" to worker $workerid");
            OpenQA::IPC->ipc->emit_signal('websockets', 'command_failed', $workerid, $msg);
        }
    }
    else {
        OpenQA::IPC->ipc->emit_signal('websockets', 'command_sent', $workerid, $msg);
    }
}

sub ws_send_all {
    my ($msg) = @_;
    foreach my $workerid (keys(%$worker_sockets)) {
        ws_send($workerid, $msg);
    }
}

sub check_authorized {
    my ($self)    = @_;
    my $headers   = $self->req->headers;
    my $key       = $headers->header('X-API-Key');
    my $hash      = $headers->header('X-API-Hash');
    my $timestamp = $headers->header('X-API-Microtime');
    my $user;
    $self->app->log->debug($key ? "API key from client: *$key*" : "No API key from client.");

    my $schema = OpenQA::Schema::connect_db;
    my $api_key = $schema->resultset("ApiKeys")->find({key => $key});
    if ($api_key) {
        if (time - $timestamp <= 300) {
            my $exp = $api_key->t_expiration;
            # It has no expiration date or it's in the future
            if (!$exp || $exp->epoch > time) {
                if (my $secret = $api_key->secret) {
                    my $sum = hmac_sha1_sum($self->req->url->to_string . $timestamp, $secret);
                    $user = $api_key->user;
                    $self->app->log->debug(sprintf "API auth by user: %s, operator: %d", $user->username, $user->is_operator);
                }
            }
        }
    }
    return 1 if ($user && $user->is_operator);

    $self->render(json => {error => "Not authorized"}, status => 403);
    return;
}

sub ws_create {
    my ($self)   = @_;
    my $workerid = $self->param('workerid');
    my $worker   = _validate_workerid($workerid);
    unless ($worker) {
        return $self->render(text => 'Unauthorized', status =>);
    }
    # upgrade connection to websocket by subscribing to events
    $self->on(json   => \&_message);
    $self->on(finish => \&_finish);
    ws_add_worker($workerid, $self->tx->max_websocket_size(10485760));

    my $workerinfo = {
        id       => $worker->id,
        host     => $worker->host,
        instance => $worker->instance,
        status   => $worker->status
    };
    $workerinfo->{properties} = {};
    for my $p ($worker->properties->all) {
        next if ($p->key eq 'JOBTOKEN');
        $workerinfo->{properties}->{$p->key} = $p->value;
    }
    OpenQA::IPC->ipc->emit_signal('websockets', 'worker_connected', $workerinfo);

    return $self->render(text => 'ack', status => 101);
}

sub ws_is_worker_connected {
    my ($workerid) = @_;
    defined $worker_sockets->{$workerid} ? 1 : 0;
}

# internal helpers
sub _validate_workerid {
    my ($workerid) = @_;
    my $schema     = OpenQA::Schema::connect_db;
    my $worker     = $schema->resultset("Workers")->find($workerid);
}

sub _get_workerid {
    my ($tx) = @_;
    my $ret;
    while (my ($id, $stored_tx) = each %$worker_sockets) {
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

    my $workerid = _get_workerid($ws->tx);
    unless ($workerid) {
        $ws->app->log->error('Worker ID not found for given connection during connection close');
        return;
    }
    $ws->app->log->debug("Worker $workerid websocket connection closed - $code\n");
    ws_remove_worker($workerid);
    OpenQA::IPC->ipc->emit_signal('websockets', 'worker_disconnected', $workerid);
}

sub _message {
    my ($ws, $json) = @_;
    my $workerid = _get_workerid($ws->tx);
    unless ($workerid) {
        $ws->app->log->warn("A message received from unknown worker connection");
        return;
    }
    unless (ref($json) eq 'HASH') {
        use Data::Dumper;
        $ws->app->log->error(sprintf('Received unexpected WS message "%s from worker %u', Dumper($json), $workerid));
        return;
    }

    my $worker = _validate_workerid($workerid);
    $worker->seen();
    if ($json->{type} eq 'ok') {
        $ws->tx->send({json => {type => 'ok'}});
    }
    elsif ($json->{type} eq 'status') {
        # handle job status update through web socket
        my $jobid  = $json->{jobid};
        my $status = $json->{data};
        my $job    = $ws->app->schema->resultset("Jobs")->find($jobid);
        return $ws->tx->send(json => {result => 'nack'}) unless $job;
        my $ret = $job->update_status($status);
        $ws->tx->send({json => $ret});
    }
    else {
        $ws->app->log->error(sprintf('Received unknown message type "%s" from worker %u', $json->{type}, $workerid));
    }
}

no warnings 'redefine';
sub new {
    my ($class, $reactor) = @_;
    # load pligns
    $plugins = Mojolicious::Plugins->new;
    push @{$plugins->namespaces}, 'OpenQA::WebSockets';
    # always load DBus plugin, need for OpenQA IPC
    $plugins->register_plugin('DBus', $reactor);
    # go through config file and load enabled plugins
    # FIXME ^

    # TODO: read openQA config
    #     $self->defaults(appname => 'openQA::WebSockets');
    #
    #     $self->_read_config;
    #     my $logfile = $ENV{OPENQA_WS_LOGFILE} || $self->config->{logging}->{file};
    #     $self->log->path($logfile);
    #
    #     if ($logfile && $self->config->{logging}->{level}) {
    #         $self->log->level($self->config->{logging}->{level});
    #     }
    #     if ($ENV{OPENQA_SQL_DEBUG} // $self->config->{logging}->{sql_debug} // 'false' eq 'true') {
    #         # avoid enabling the SQL debug unless we really want to see it
    #         # it's rather expensive
    #         db_profiler::enable_sql_debugging($self);
    #     }

    # Mojolicious startup
    # use port one higher than WebAPI
    my $port = 9527;
    if ($ENV{MOJO_LISTEN} && $ENV{MOJO_LISTEN} =~ /.*:(\d{1,5})\/?$/) {
        $port = $1;
    }

    # routes
    under \&check_authorized;
    websocket '/ws/:workerid' => [workerid => qr/\d+/] => \&ws_create;

    # no cookies for worker, no secrets to protect
    app->secrets(['nosecretshere']);
    return Mojo::Server::Daemon->new(app => app, listen => ["http://localhost:$port"]);
}

sub run {
    # config Mojo to get reactor
    my $server = OpenQA::WebSockets->new(Mojo::IOLoop->singleton->reactor);
    # start IOLoop
    $server->run;
}

1;
