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

package OpenQA::Worker::WebUIConnection;
use Mojo::Base 'Mojo::EventEmitter';

use OpenQA::Utils qw(log_error log_debug log_warning log_info feature_scaling rand_range logistic_map_steps);
use OpenQA::Constants qw(WEBSOCKET_API_VERSION MAX_TIMER MIN_TIMER);
use OpenQA::Worker::CommandHandler;

use Mojo::IOLoop;

has 'webui_host';         # hostname:port of the web UI to connect to
has 'url';                # URL of the web UI to connect to - initially deduced from webui_host (Mojo::URL instance)
has 'ua';                 # the OpenQA::Client used to do connections
has 'status';             # the status of the connection: new, registering, establishing_ws, connected, failed, disabled
has 'worker';             # the worker this client belongs to
has 'worker_id';          # the ID the web UI uses to track this worker (populated on registration)
has 'testpool_server';    # testpool server for this web UI host
has 'working_directory';  # share directory for this web UI host
has 'cache_directory';    # cache directory for this web UI host

# the websocket connection to receive commands from the web UI and send the status (Mojo::Transaction::WebSockets instance)
has 'websocket_connection';

# stores the "population" of the web UI host which is updated when receiving that info via web sockets
has 'webui_host_population';

# interval for overall worker status updates; automatically set when needed (unless set manually)
has 'send_status_interval';

sub new {
    my ($class, $webui_host, $cli_options) = @_;

    my $url;
    if ($webui_host !~ '/') {
        $url = Mojo::URL->new->scheme('http')->host_port($webui_host);
    }
    else {
        $url = Mojo::URL->new($webui_host);
    }

    my $ua = OpenQA::Client->new(
        api       => $url->host,
        apikey    => $cli_options->{apikey},
        apisecret => $cli_options->{apisecret},
    );
    $ua->base_url($url);

    # append relative paths to the existing ones
    $url->path('/api/v1/');

    # disable keep alive to avoid time outs in strange places - we only reach the
    # webapi once in a while so take the price of reopening the connection every time
    # we do
    $ua->max_connections(0);

    unless ($ua->apikey && $ua->apisecret) {
        die "API key and secret are needed for the worker connecting $webui_host\n";
    }

    return $class->SUPER::new(
        webui_host => $webui_host,
        url        => $url,
        ua         => $ua,
        status     => 'new',
    );
}

sub DESTROY {
    my ($self) = @_;
    return if ${^GLOBAL_PHASE} eq 'DESTRUCT';

    $self->_remove_timer;
}

sub _remove_timer {
    my ($self) = @_;

    if (my $timer_id = delete $self->{_send_status_timer}) {
        Mojo::IOLoop->remove($timer_id);
    }
}

sub _set_status {
    my ($self, $status, $event_data) = @_;

    $event_data->{client} = $self;
    $event_data->{status} = $status;
    $self->status($status);
    $self->emit(status_changed => $event_data);
}

# registers the worker in the web UI and establishes the websocket connection
sub register {
    my ($self) = @_;

    $self->_set_status(registering => {});

    # get required parameter
    my $worker            = $self->worker or die 'client has no worker assigned';
    my $webui_host        = $self->webui_host;
    my $worker_hostname   = $worker->worker_hostname;
    my $capabilities      = $worker->capabilities;
    my $working_directory = $self->working_directory;
    my $ua                = $self->ua;
    my $url               = $self->url->clone;
    if (!$webui_host || !$working_directory || !$ua || !$url) {
        die 'client not correctly initialized before registration';
    }

    # finish any existing websocket connection
    $self->finish_websocket_connection;

    # register via REST API
    $url->path('workers');
    $url->query($capabilities);
    my $tx = $ua->post($url, json => $capabilities);
    if (my $error = $tx->error) {
        my $err_code = $error->{code};
        if ($err_code) {
            if ($err_code =~ /^4\d\d$/) {
                # don't retry when 4xx codes are returned. There is problem with scheduler
                $self->_set_status(
                    disabled => {
                        error_message => sprintf('server refused with code %s: %s', $tx->error->{code}, $tx->res->body)}
                );
            }
            else {
                $self->_set_status(
                    failed => {
                        error_message =>
                          sprintf('failed to register worker %s - %s:%s', $webui_host, $err_code, $tx->res->body)});
            }
        }
        else {
            $self->_set_status(
                failed => {
                    error_message => "Unable to connect to host $webui_host"
                });
        }
        return undef;
    }
    my $worker_id = $tx->res->json->{id};
    $self->worker_id($worker_id);
    if (!defined $worker_id) {
        $self->_set_status(
            disabled => {
                error_message => "Host $webui_host did not return a worker ID"
            });
        return undef;
    }

    # setup the websocket connection which is mainly required to get *new* jobs but not strictly necessary while
    # already running a job
    $self->_setup_websocket_connection();
}

sub _setup_websocket_connection {
    my ($self, $websocket_url) = @_;

    # prevent messing around when there's still an active websocket connection
    my $websocket_connection = $self->websocket_connection;
    if ($websocket_connection) {
        return undef;
    }

   # make URL for websocket connection unless specified as argument (which would be the case when following redirection)
    if (!$websocket_url) {
        my $worker_id  = $self->worker_id;
        my $webui_host = $self->webui_host;
        if (!$worker_id) {
            $self->_set_status(
                disabled => {
                    error_message => "Unable to establish ws connection to $webui_host without worker ID"
                });
        }
        $websocket_url = $self->url->clone;
        if ($websocket_url->scheme eq 'http') {
            $websocket_url->scheme('ws');
        }
        elsif ($websocket_url->scheme eq 'https') {
            $websocket_url->scheme('wss');
        }
        $websocket_url->path("ws/$worker_id");
    }

    $self->_set_status(establishing_ws => {url => $websocket_url});

    # We need to make sure not to reconnect in subprocesses
    my $websocket_pid = $$;

    # start the websocket connection
    $self->ua->websocket(
        $websocket_url,
        {'Sec-WebSocket-Extensions' => 'permessage-deflate'},
        sub {
            my ($ua, $tx) = @_;

            # handle case when we've only got a regular HTTP connection
            if (!$tx->is_websocket) {
                $self->websocket_connection(undef);
                if (my $location_header = ($tx->completed ? $tx->res->headers->location : undef)) {
                    log_debug("Following ws redirection to: $location_header");
                    return $self->_setup_websocket_connection();
                }

                my $error         = $tx->error;
                my $error_message = "Unable to upgrade to ws connection via $websocket_url";
                if ($error && $error->{code}) {
                    $error_message .= ", code $error->{code}";
                }
                $self->_set_status(failed => {error_message => $error_message});
                return undef;
            }

            my $command_handler = OpenQA::Worker::CommandHandler->new($self);
            $tx->on(
                json => sub {
                    $command_handler->handle_command(@_);
                });
            $tx->on(
                finish => sub {
                    # uncoverable subroutine
                    # https://progress.opensuse.org/issues/55364
                    my (undef, $code, $reason) = @_;

                    # Subprocesses reset the event loop (which triggers this event),
                    # and since only the main worker process uses the WebSocket we
                    # can safely ignore this (and do not want to reconnect)
                    return unless $websocket_pid == $$;

                    # ignore if the connection was disabled from our side
                    if (!$self->websocket_connection) {
                        log_debug("Websocket connection to $websocket_url finished from our side.");
                        return undef;
                    }

                    $reason //= 'no reason';
                    $self->websocket_connection(undef);
                    $self->_set_status(
                        failed => {
                            error_message =>
                              "Websocket connection to $websocket_url finished by remote side with code $code, $reason"
                        });

                    # note: The worker is supposed to handle this event and e.g. try to re-register again.
                });
            $tx->max_websocket_size(10485760);
            $self->websocket_connection($tx);
            $self->send_status_interval(undef);
            $self->send_status();
            $self->_set_status(connected => {});
        });
}

sub finish_websocket_connection {
    my ($self) = @_;

    if (my $websocket_connection = $self->websocket_connection) {
        $self->websocket_connection(undef);
        $websocket_connection->finish();
    }
}

sub disable {
    my ($self, $reason) = @_;

    my $webui_host = $self->webui_host;
    $self->_set_status(
        disabled => {
            error_message => $reason // "Connection with $webui_host disabled due to incompatible version",
        });
    $self->finish_websocket_connection;
}

# define list of HTTP error codes which indicate that the web UI is overloaded or down for maintenance
# (in these cases the re-try delay should be increased)
my %BUSY_ERROR_CODES = map { $_ => 1 } 502, 503, 504, 598;

sub _retry_delay {
    my ($self, $is_webui_busy) = @_;
    my $key                    = $is_webui_busy ? 'RETRY_DELAY_IF_WEBUI_BUSY' : 'RETRY_DELAY';
    my $settings               = $self->worker->settings;
    my $host_specific_settings = $settings->webui_host_specific_settings->{$self->webui_host} // {};
    return $host_specific_settings->{$key} // $settings->global_settings->{$key};
}

# sends a command to the web UI via its REST API
# note: This function may be called when the websocket connection has been interrupted as long as we still have a
#       worker ID. If the websocket connection is down that should not affect any of the REST API calls.
sub send {
    my ($self, $method, $path, %args) = @_;

    my $host      = $self->webui_host;
    my $params    = $args{params};
    my $json_data = $args{json};
    my $callback  = $args{callback} // sub { };
    my $tries     = $args{tries} // 3;

    # if set ignore errors completely and don't retry
    my $ignore_errors = $args{ignore_errors} // 0;

    # if set apply usual error handling (retry attempts) but treat failure as non-critical
    my $non_critical = $args{non_critical} // 0;

    if (!$self->worker_id) {
        die "attempt to send command to web UI $host with no worker ID";
    }

    # build URL
    $method = uc $method;
    my $ua_url = $self->url->clone;
    my $ua     = $self->ua;
    $ua_url->path($path);
    $ua_url->query($params) if $params;

    # adjust port for separate daemons like the liveviewhandler
    # (see also makeWsUrlAbsolute() in openqa.js)
    if (my $service_port_delta = $args{service_port_delta}) {
        if (my $webui_port = $ua_url->port()) {
            $ua_url->port($webui_port + $service_port_delta);
        }
    }
    log_debug("REST-API call: $method $ua_url");

    my @args = ($method, $ua_url);
    if ($json_data) {
        push(@args, 'json', $json_data);
    }

    my $tx = $ua->build_tx(@args);
    if ($callback eq "no") {
        $ua->start($tx);
        return undef;
    }
    my $cb;
    $cb = sub {
        my ($ua, $tx, $tries) = @_;
        if (!$tx->error && $tx->res->json) {
            my $res = $tx->res->json;
            return $callback->($res);
        }
        elsif ($ignore_errors) {
            return $callback->();
        }

        # handle error case
        --$tries;
        my $err = $tx->error;
        my $msg;
        my $is_webui_busy;

        # format error message for log
        if ($tx->res && $tx->res->json) {
            # JSON API might provide error message
            $msg = $tx->res->json->{error};
        }
        $msg //= $err->{message};
        if (my $error_code = $err->{code}) {
            $msg = "$error_code response: $msg";
            if ($error_code == 404) {
                # don't retry on 404 errors (in this case we can't expect different
                # results on further attempts)
                $tries = 0;
            }
            else {
                $is_webui_busy = $BUSY_ERROR_CODES{$error_code};
            }
        }
        else {
            $msg           = "Connection error: $msg";
            $is_webui_busy = 1 if $err->{message} =~ qr/timeout/i;
        }
        $self->{_last_error} = $msg;
        log_error("REST-API error ($method $ua_url): $msg (remaining tries: $tries)");

        # handle critical error when no more attempts remain
        if ($tries <= 0 && !$non_critical) {
            # abort the current job, we're in trouble - but keep running to grab the next
            my $worker             = $self->worker;
            my $current_webui_host = $worker->current_webui_host;
            if ($current_webui_host && $current_webui_host eq $self->webui_host) {
                $worker->stop_current_job('api-failure');
            }
            $callback->();
            return undef;
        }

        # handle non-critical error when no more attempts remain
        if ($tries <= 0) {
            $callback->();
            return undef;
        }

        # retry in 5 seconds or a minute if there are remaining attempts
        $tx = $ua->build_tx(@args);
        Mojo::IOLoop->timer(
            $self->_retry_delay($is_webui_busy),
            sub {
                $ua->start($tx => sub { $cb->(@_, $tries) });
            });
    };
    $ua->start($tx => sub { $cb->(@_, $tries) });
}

sub last_error {
    my ($self) = @_;
    return $self->{_last_error};
}

sub reset_last_error {
    my ($self) = @_;
    delete $self->{_last_error};
}

sub send_artefact {
    my ($self, $job_id, $form) = @_;

    my $md5  = $form->{md5};
    my $name = $form->{file}{filename};
    log_debug("Uploading artefact $name" . ($md5 ? " as $md5" : ''));

    my $ua  = $self->ua;
    my $url = $self->url->clone;
    $url->path("jobs/$job_id/artefact");

    my $tx = $ua->post($url => form => $form);
    if (my $err = $tx->error) { log_error("Uploading artefact $name failed: $err->{message}") }
}

sub _calculate_status_update_interval {
    my ($self) = @_;

    my $status_update_interval = $self->send_status_interval;
    return $status_update_interval if ($status_update_interval);

    # do dubious calculations to balance the load on the websocket server
    # (see https://github.com/os-autoinst/openQA/pull/1486 and https://progress.opensuse.org/issues/25960)
    my $i            = $self->worker_id // $self->worker->instance_number;
    my $imax         = $self->webui_host_population || 1;
    my $scale_factor = $imax;
    my $steps        = 215;
    my $r            = 3.81199961;
    my $population   = feature_scaling($i, $imax, 0, 1);
    my $status_timer
      = abs(feature_scaling(logistic_map_steps($steps, $r, $population) * $scale_factor, $imax, MIN_TIMER, MAX_TIMER));
    $status_timer = $status_timer > MIN_TIMER
      && $status_timer < MAX_TIMER ? $status_timer : $status_timer > MAX_TIMER ? MAX_TIMER : MIN_TIMER;

    $self->send_status_interval($status_update_interval = sprintf("%.2f", $status_timer));
    return $status_update_interval;
}

# sends the overall worker status
sub send_status {
    my ($self) = @_;

    # ensure an ongoing timer is cancelled in case send_status has been called manually
    if (my $send_status_timer = delete $self->{_send_status_timer}) {
        Mojo::IOLoop->remove($send_status_timer);
    }

    # send the worker status (unless the websocket connection has been lost)
    my $websocket_connection = $self->websocket_connection;
    return undef unless $websocket_connection;
    $websocket_connection->send(
        {json => $self->worker->status},
        sub {

            # continue sending status updates (unless the websocket connection has been lost)
            return undef unless $self->websocket_connection;

            my $status_update_interval = $self->_calculate_status_update_interval;
            $self->{_send_status_timer} = Mojo::IOLoop->timer(
                $status_update_interval,
                sub {
                    $self->send_status;
                });
        });
}

# send "quit" message when intentionally "going offline" so the worker is immediately considered
# offline by the web UI and not just after WORKERS_CHECKER_THRESHOLD seconds
sub quit {
    my ($self, $callback) = @_;

    # ensure we're not sending any further status updates (which would let the web UI consider the
    # worker online again)
    if (my $send_status_timer = delete $self->{_send_status_timer}) {
        Mojo::IOLoop->remove($send_status_timer);
    }

    # do nothing if the ws connection has been lost anyways
    my $websocket_connection = $self->websocket_connection;
    if (!defined $websocket_connection) {
        Mojo::IOLoop->next_tick($callback) if defined $callback;
        return undef;
    }

    $websocket_connection->send({json => {type => 'quit'}}, $callback);
}

1;
