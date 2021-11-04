# Copyright 2019-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Worker::WebUIConnection;
use Mojo::Base 'Mojo::EventEmitter', -signatures;

use OpenQA::Log qw(log_error log_debug log_warning log_info);
use OpenQA::Utils qw(feature_scaling rand_range logistic_map_steps);
use OpenQA::Constants qw(WEBSOCKET_API_VERSION WORKER_SR_API_FAILURE MAX_TIMER MIN_TIMER);
use OpenQA::Worker::CommandHandler;

use Mojo::IOLoop;

has 'webui_host';    # hostname:port of the web UI to connect to
has 'url';    # URL of the web UI to connect to - initially deduced from webui_host (Mojo::URL instance)
has 'ua';    # the OpenQA::Client used to do connections
has 'status';    # the status of the connection: new, registering, establishing_ws, connected, failed, disabled
has 'worker';    # the worker this client belongs to
has 'worker_id';    # the ID the web UI uses to track this worker (populated on registration)
has 'testpool_server';    # testpool server for this web UI host
has 'working_directory';    # share directory for this web UI host
has 'cache_directory';    # cache directory for this web UI host

# the websocket connection to receive commands from the web UI and send the status (Mojo::Transaction::WebSockets instance)
has 'websocket_connection';

# stores the "population" of the web UI host which is updated when receiving that info via web sockets
has 'webui_host_population';

# interval for overall worker status updates; automatically set when needed (unless set manually)
has 'send_status_interval';

sub new ($class, $webui_host, $cli_options) {
    my $url = $webui_host !~ '/' ? Mojo::URL->new->scheme('http')->host_port($webui_host) : Mojo::URL->new($webui_host);
    my $ua = OpenQA::Client->new(
        api => $url->host,
        apikey => $cli_options->{apikey},
        apisecret => $cli_options->{apisecret},
    );
    $ua->base_url($url);

    # append relative paths to the existing ones
    $url->path('/api/v1/');

    # disable keep alive to avoid time outs in strange places - we only reach the
    # webapi once in a while so take the price of reopening the connection every time
    # we do
    $ua->max_connections(0)->max_redirects(3);

    die "API key and secret are needed for the worker connecting $webui_host\n" unless ($ua->apikey && $ua->apisecret);

    return $class->SUPER::new(
        webui_host => $webui_host,
        url => $url,
        ua => $ua,
        status => 'new',
    );
}

sub DESTROY ($self) {
    return if ${^GLOBAL_PHASE} eq 'DESTRUCT';
    $self->_remove_timer;
}

sub _remove_timer ($self) {
    if (my $timer_id = delete $self->{_send_status_timer}) {
        Mojo::IOLoop->remove($timer_id);
    }
}

sub _set_status ($self, $status, $event_data) {
    $event_data->{client} = $self;
    $event_data->{status} = $status;
    $self->status($status);
    $self->emit(status_changed => $event_data);
}

# registers the worker in the web UI and establishes the websocket connection
sub register ($self) {
    $self->_set_status(registering => {});

    # get required parameter
    my $worker = $self->worker or die 'client has no worker assigned';
    my $webui_host = $self->webui_host;
    my $worker_hostname = $worker->worker_hostname;
    my $capabilities = $worker->capabilities;
    my $working_dir = $self->working_directory;
    my $ua = $self->ua;
    my $url = $self->url->clone;
    die 'client not correctly initialized before registration' unless ($webui_host && $working_dir && $ua && $url);

    # finish any existing websocket connection
    $self->finish_websocket_connection;

    # register via REST API
    $url->path('workers');
    $url->query($capabilities);
    my $tx = $ua->post($url, json => $capabilities);
    my $json_res = $tx->res->json;
    if (my $error = $tx->error) {
        my $error_code = $error->{code};
        my $error_class = $error_code ? "$error_code response" : 'connection error';
        my $error_message;
        $error_message = $json_res->{error} if ref($json_res) eq 'HASH';
        $error_message //= $tx->res->body || $error->{message};
        $error_message = "Failed to register at $webui_host - $error_class: $error_message";
        my $status = (defined $error_code && $error_code =~ /^4\d\d$/ ? 'disabled' : 'failed');
        $self->{_last_error} = $error_message;
        $self->_set_status($status => {error_message => $error_message});
        return undef;
    }
    my $worker_id = $json_res->{id};
    $self->worker_id($worker_id);
    if (!defined $worker_id) {
        $self->_set_status(
            disabled => {error_message => "Failed to register at $webui_host: host did not return a worker ID"});
        return undef;
    }

    # setup the websocket connection which is mainly required to get *new* jobs but not strictly necessary while
    # already running a job
    $self->_setup_websocket_connection();
}

sub _setup_websocket_connection ($self, $websocket_url = undef) {
    # prevent messing around when there's still an active websocket connection
    return undef if $self->websocket_connection;

   # make URL for websocket connection unless specified as argument (which would be the case when following redirection)
    if (!$websocket_url) {
        my $worker_id = $self->worker_id;
        my $webui_host = $self->webui_host;
        if (!$worker_id) {
            $self->_set_status(
                disabled => {
                    error_message => "Unable to establish ws connection to $webui_host without worker ID"
                });
        }
        $websocket_url = $self->url->clone;
        my %ws_scheme = (http => 'ws', https => 'wss');
        $websocket_url->scheme($ws_scheme{$websocket_url->scheme}) if $websocket_url->scheme =~ /http|https/;
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

                my $error = $tx->error;
                my $error_message = "Unable to upgrade to ws connection via $websocket_url";
                $error_message .= ", code $error->{code}" if ($error && $error->{code});
                $self->_set_status(failed => {error_message => $error_message});
                return undef;
            }

            my $command_handler = OpenQA::Worker::CommandHandler->new($self);
            $tx->on(
                json => sub {
                    $command_handler->handle_command(@_);
                });
            $tx->on(
                # uncoverable statement
                finish => sub ($tx, $code, $reason = undef) {
                    # https://progress.opensuse.org/issues/55364
                    # uncoverable subroutine
                    # uncoverable statement
                    $reason //= 'no reason';

                    # Subprocesses reset the event loop (which triggers this event),
                    # and since only the main worker process uses the WebSocket we
                    # can safely ignore this (and do not want to reconnect)
                    # uncoverable statement
                    return unless $websocket_pid == $$;

                    # ignore if the connection was disabled from our side
                    # uncoverable statement
                    return log_debug("Websocket connection to $websocket_url finished from our side.")
                      unless $self->websocket_connection;

                    $self->websocket_connection(undef)->_set_status(    # uncoverable statement
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

sub finish_websocket_connection ($self) {
    if (my $websocket_connection = $self->websocket_connection) {
        $self->websocket_connection(undef);
        $websocket_connection->finish();
    }
}

# define list of HTTP error codes which indicate that the web UI is overloaded or down for maintenance
# (in these cases the re-try delay should be increased)
my %BUSY_ERROR_CODES = map { $_ => 1 } 408, 425, 502, 503, 504, 598;

sub _retry_delay ($self, $is_webui_busy) {
    my $key = $is_webui_busy ? 'RETRY_DELAY_IF_WEBUI_BUSY' : 'RETRY_DELAY';
    my $settings = $self->worker->settings;
    my $host_specific_settings = $settings->webui_host_specific_settings->{$self->webui_host} // {};
    return $host_specific_settings->{$key} // $settings->global_settings->{$key};
}

sub evaluate_error ($self, $tx, $remaining_tries) {
    my ($msg, $retry_delay, $is_webui_busy);
    return ($msg, $retry_delay) unless my $error = $tx->error;
    $$remaining_tries -= 1;
    $msg = $tx->res->json->{error} if $tx->res && $tx->res->json;
    $msg = $error->{message} unless $msg;
    if (my $error_code = $error->{code}) {
        $msg = "$error_code response: $msg";
        if ($error_code < 500 && $error_code != 408 && $error_code != 425 && $error_code != 490) {
            # don't retry on most 4xx errors (in this case we can't expect different results on further attempts)
            $$remaining_tries = 0;
        }
        else {
            $is_webui_busy = $BUSY_ERROR_CODES{$error_code};
        }
    }
    else {
        $msg = "Connection error: $msg";
        $is_webui_busy = 1 if $error->{message} =~ qr/timeout/i;
    }
    $retry_delay = $self->_retry_delay($is_webui_busy) if $$remaining_tries > 0;
    return ($msg, $retry_delay);
}

sub configured_retries ($self) {
    $ENV{OPENQA_WORKER_CONNECT_RETRIES} // $self->worker->settings->global_settings->{RETRIES} // 60;
}

# sends a command to the web UI via its REST API
# note: This function may be called when the websocket connection has been interrupted as long as we still have a
#       worker ID. If the websocket connection is down that should not affect any of the REST API calls.
sub send ($self, $method, $path, %args) {
    my $host = $self->webui_host;
    my $params = $args{params};
    my $json_data = $args{json};
    my $callback = $args{callback} // sub { };
    my $tries = $args{tries} // $self->configured_retries;

    # if set ignore errors completely and don't retry
    my $ignore_errors = $args{ignore_errors} // 0;

    # if set apply usual error handling (retry attempts) but treat failure as non-critical
    my $non_critical = $args{non_critical} // 0;

    die "attempt to send command to web UI $host with no worker ID" unless $self->worker_id;

    # build URL
    $method = uc $method;
    my $ua_url = $self->url->clone;
    my $ua = $self->ua;
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
    push(@args, 'json', $json_data) if $json_data;
    my $tx = $ua->build_tx(@args);
    if ($callback eq "no") {
        $ua->start($tx);
        return undef;
    }
    my $cb;
    $cb = sub {
        my ($ua, $tx, $tries) = @_;

        # check for errors
        my ($error_msg, $retry_delay) = $self->evaluate_error($tx, \$tries);
        return $callback->($tx->res->json) if !$error_msg && $tx->res->json;
        return $callback->() if $ignore_errors;
        $self->{_last_error} = $error_msg;
        log_error("REST-API error ($method $ua_url): $error_msg (remaining tries: $tries)");

        # handle critical error when no more attempts remain
        if ($tries <= 0 && !$non_critical) {
            # abort the current job, we're in trouble - but keep running to grab the next
            my $worker = $self->worker;
            my $current_webui_host = $worker->current_webui_host;
            if ($current_webui_host && $current_webui_host eq $self->webui_host) {
                $worker->stop_current_job(WORKER_SR_API_FAILURE);
            }
            $callback->();
            return undef;
        }

        # handle non-critical error when no more attempts remain
        if ($tries <= 0) {
            # uncoverable subroutine
            # we reach here in full stack tests which produce flaky results
            # https://progress.opensuse.org/issues/55364
            $callback->();
            return undef;
        }

        # retry later if there are remaining attempts
        $tx = $ua->build_tx(@args);
        Mojo::IOLoop->timer(
            $retry_delay,
            sub {
                $ua->start($tx => sub { $cb->(@_, $tries) });
            });
    };
    $ua->start($tx => sub { $cb->(@_, $tries) });
}

sub last_error ($self) { $self->{_last_error} }

sub reset_last_error ($self) { delete $self->{_last_error} }

sub add_context_to_last_error ($self, $context) {
    my $last_error = $self->{_last_error};
    $self->{_last_error} = "$last_error on $context" if $last_error;
}

sub _calculate_status_update_interval ($self) {
    my $status_update_interval = $self->send_status_interval;
    return $status_update_interval if ($status_update_interval);

    # do dubious calculations to balance the load on the websocket server
    # (see https://github.com/os-autoinst/openQA/pull/1486 and https://progress.opensuse.org/issues/25960)
    my $i = $self->worker_id // $self->worker->instance_number;
    my $imax = $self->webui_host_population || 1;
    my $scale_factor = $imax;
    my $steps = 215;
    my $r = 3.81199961;
    my $population = feature_scaling($i, $imax, 0, 1);
    my $status_timer
      = abs(feature_scaling(logistic_map_steps($steps, $r, $population) * $scale_factor, $imax, MIN_TIMER, MAX_TIMER));
    $status_timer = $status_timer > MIN_TIMER
      && $status_timer < MAX_TIMER ? $status_timer : $status_timer > MAX_TIMER ? MAX_TIMER : MIN_TIMER;

    $self->send_status_interval($status_update_interval = sprintf("%.2f", $status_timer));
    return $status_update_interval;
}

# sends the overall worker status
sub send_status ($self) {
    # ensure an ongoing timer is cancelled in case send_status has been called manually
    if (my $send_status_timer = delete $self->{_send_status_timer}) {
        Mojo::IOLoop->remove($send_status_timer);
    }

    # send the worker status (unless the websocket connection has been lost)
    my $websocket_connection = $self->websocket_connection;
    return undef unless $websocket_connection;
    my $status = $self->worker->status;

    $websocket_connection->send(
        {json => $status},
        sub {

            # continue sending status updates (unless the websocket connection has been lost)
            return undef unless $self->websocket_connection;

            my $status_update_interval = $self->_calculate_status_update_interval;
            my $webui_host = $self->webui_host;
            log_warning "$status->{reason} - checking again for web UI '$webui_host' in $status_update_interval s"
              if $status->{reason};
            $self->{_send_status_timer} = Mojo::IOLoop->timer($status_update_interval, sub { $self->send_status });
        });
}

# send "quit" message when intentionally "going offline" so the worker is immediately considered
# offline by the web UI and not just after the timeout
sub quit ($self, $callback) {
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

# send "rejected" message when refusing to take one or more jobs assigned by the web UI
sub reject_jobs ($self, $job_ids, $reason, $callback = undef) {
    # send rejection message via web sockets if connected
    my $websocket_connection = $self->websocket_connection;
    return $websocket_connection->send({json => {type => 'rejected', job_ids => $job_ids, reason => $reason}},
        $callback)
      if defined $websocket_connection;

    # try sending the message when the web socket connection becomes available again
    $self->once(connected => sub { $self->reject_jobs($job_ids, $reason, $callback); });
}

1;
