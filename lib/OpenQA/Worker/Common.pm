# Copyright (C) 2015-2017 SUSE LLC
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

package OpenQA::Worker::Common;
use 5.018;
use warnings;
use feature 'state';

use Carp;
use POSIX 'uname';
use Mojo::URL;
use OpenQA::Client;
use OpenQA::Utils qw(log_error log_debug log_warning log_info);

use base 'Exporter';
our @EXPORT = qw($job $verbose $instance $worker_settings $pooldir $nocleanup
  $hosts $ws_to_host $current_host
  $worker_caps $testresults update_setup_status
  STATUS_UPDATES_SLOW STATUS_UPDATES_FAST
  add_timer remove_timer change_timer get_timer
  api_call verify_workerid register_worker ws_call);

# Exported variables
our $job;
our $verbose  = 0;
our $instance = 'manual';
our $worker_settings;
our $pooldir;
our $nocleanup = 0;
our $testresults;
our $worker_caps;

# package global variables
# HASHREF with structure
# {hostname => {url => Mojo::URL, ua => OpenQA::Client, ws => Mojo::Transaction::WebSockets}, workerid => uint}
our $hosts;
our $ws_to_host;

# undef unless working on job - then contains hostname of webui we are working for
our $current_host;

my ($sysname, $hostname, $release, $version, $machine) = POSIX::uname();

# global constants
use constant {
    STATUS_UPDATES_SLOW => 10,
    STATUS_UPDATES_FAST => 0.5,
};

# the template noted what architecture are known
my %cando = (
    i586   => ['i586'],
    i686   => ['i686', 'i586'],
    x86_64 => ['x86_64', 'i686', 'i586'],

    ppc     => ['ppc'],
    ppc64   => ['ppc64le', 'ppc64', 'ppc'],
    ppc64le => ['ppc64le', 'ppc64', 'ppc'],

    s390  => ['s390'],
    s390x => ['s390x', 's390'],

    aarch64 => ['aarch64'],
);

## Mojo timers ids
my $timers = {
    # check for new job
    check_job => undef,
    # update status of running job
    update_status => undef,
    # check for crashed backend and its running status
    check_backend => undef,
    # trigger stop_job if running for > $max_job_time
    job_timeout => undef,
    # app call retry
    api_call => undef,
};

sub add_timer {
    my ($timer, $timeout, $callback, $nonrecurring) = @_;
    die "must specify callback\n" unless $callback && ref $callback eq 'CODE';
    # skip if timer already defined, but not if one shot timer (avoid the need to call remove_timer for nonrecurring)
    return if ($timer && $timers->{$timer} && !$nonrecurring);
    log_debug("## adding timer $timer $timeout") if $verbose;
    my $timerid;
    if ($nonrecurring) {
        $timerid = Mojo::IOLoop->timer($timeout => $callback);
    }
    else {
        $timerid = Mojo::IOLoop->recurring($timeout => $callback);
    }
  # store timerid for global timers so we can stop them later
  # there are still non-global host related timers, their $timerid is stored in respective $hosts->{$host}{timers} field
    $timers->{$timer} = [$timerid, $callback] if $timer;

    return $timerid;
}

sub remove_timer {
    my ($timer) = @_;
    return unless $timer;
    log_debug("## removing timer $timer") if $verbose;
    my $timerid = $timer;
    if ($timers->{$timer}) {
        # global timers needs translation to actual timerid
        $timerid = $timers->{$timer}->[0];
        delete $timers->{$timer};
    }
    Mojo::IOLoop->remove($timerid);
}

sub change_timer {
    my ($timer, $newtimeout, $callback) = @_;
    return unless ($timer && $timers->{$timer});
    log_debug("## changing timer $timer") if $verbose;
    $callback = $timers->{$timer}->[1] unless $callback;
    remove_timer($timer);
    add_timer($timer, $newtimeout, $callback);
}

sub get_timer {
    my ($timer) = @_;
    return $timers->{$timer} if $timer;
}

## prepare UA and URL for OpenQA-scheduler connection
sub api_init {
    my ($host_settings, $options) = @_;
    for my $host (@{$host_settings->{HOSTS}}) {
        my ($ua, $url);
        if ($host !~ '/') {
            $url = Mojo::URL->new->scheme('http')->host_port($host);
        }
        else {
            $url = Mojo::URL->new($host);
        }

        # Relative paths are appended to the existing one
        $url->path('/api/v1/');

        my ($apikey, $apisecret) = ($options->{apikey}, $options->{apisecret});
        $ua = OpenQA::Client->new(
            api       => $url->host,
            apikey    => $apikey,
            apisecret => $apisecret
        );
        # disable keep alive to avoid time outs in strange places - we only reach the
        # webapi once in a while so take the price of reopening the connection every time
        # we do
        $ua->max_connections(0);

        unless ($ua->apikey && $ua->apisecret) {
            die "API key and secret are needed for the worker connecting " . $url->host . "\n";
        }
        $hosts->{$host}{ua}  = $ua;
        $hosts->{$host}{url} = $url;
    }
}

# send a command to openQA API
sub api_call {
    my ($method, $path, %args) = @_;

    my $host          = $args{host} // $current_host;
    my $params        = $args{params};
    my $json_data     = $args{json};
    my $callback      = $args{callback} // sub { };
    my $ignore_errors = $args{ignore_errors} // 0;
    my $tries         = $args{tries} // 3;

    die 'No worker id or webui host set!' unless verify_workerid($host);

    $method = uc $method;
    my $ua_url = $hosts->{$host}{url}->clone;
    my $ua     = $hosts->{$host}{ua};

    $ua_url->path($path =~ s/^\///r);
    $ua_url->query($params) if $params;

    log_debug("$method $ua_url") if $verbose;

    my @args = ($method, $ua_url);

    if ($json_data) {
        push @args, 'json', $json_data;
    }

    my $tx = $ua->build_tx(@args);
    if ($callback eq "no") {
        $ua->start($tx);
        return;
    }
    my $cb;
    $cb = sub {
        my ($ua, $tx, $tries) = @_;
        if ($tx->success && $tx->success->json) {
            my $res = $tx->success->json;
            return $callback->($res);
        }
        elsif ($ignore_errors) {
            return $callback->();
        }

        # handle error case
        --$tries;
        my $err = $tx->error;
        my $msg;

        # format error message for log
        if ($tx->res && $tx->res->json) {
            # JSON API might provide error message
            $msg = $tx->res->json->{error};
        }
        $msg //= $err->{message};
        if ($err->{code}) {
            $msg = "$err->{code} response: $err->{message}";
            if ($err->{code} == 404) {
                # don't retry on 404 errors (in this case we can't expect different
                # results on further attempts)
                $tries = 0;
            }
        }
        else {
            $msg = "Connection error: $err->{message}";
        }
        OpenQA::Utils::log_error($msg . " (remaining tries: $tries)");

        if (!$tries) {
            # abort the current job, we're in trouble - but keep running to grab the next
            OpenQA::Worker::Jobs::stop_job('api-failure');
            # stop accepting jobs and schedule reregistration - keep the rest running
            $hosts->{$host}{accepting_jobs} = 0;
            add_timer("register_worker-$host", 10, sub { register_worker($host) }, 1);
            $callback->();
            return;
        }

        $tx = $ua->build_tx(@args);
        add_timer(
            '', 5,
            sub {
                $ua->start($tx => sub { $cb->(@_, $tries) });
            },
            1
        );
    };
    $ua->start($tx => sub { $cb->(@_, $tries) });
}

sub ws_call {
    my ($type, $data) = @_;
    die 'Current host not set!' unless $current_host;

    # this call is also non blocking, result and image upload is handled by json handles
    log_debug("WEBSOCKET: $type") if $verbose;
    my $ws = $hosts->{$current_host}{ws};
    $ws->send({json => {type => $type, jobid => $job->{id} || '', data => $data}});
}

sub _get_capabilities {
    my $caps = {};
    my $query_cmd;

    if ($worker_settings->{ARCH}) {
        $caps->{cpu_arch} = $worker_settings->{ARCH};
    }
    else {
        open(my $LSCPU, "-|", "LC_ALL=C lscpu");
        while (<$LSCPU>) {
            chomp;
            if (m/Model name:\s+(.+)$/) {
                $caps->{cpu_modelname} = $1;
            }
            if (m/Architecture:\s+(.+)$/) {
                $caps->{cpu_arch} = $1;
            }
            if (m/CPU op-mode\(s\):\s+(.+)$/) {
                $caps->{cpu_opmode} = $1;
            }
        }
        close($LSCPU);
    }
    open(my $MEMINFO, "<", "/proc/meminfo");
    while (<$MEMINFO>) {
        chomp;
        if (m/MemTotal:\s+(\d+).+kB/) {
            my $mem_max = $1 ? $1 : '';
            $caps->{mem_max} = int($mem_max / 1024) if $mem_max;
        }
    }
    close($MEMINFO);
    return $caps;
}

sub setup_websocket {
    my ($host) = @_;
    die unless $host;
    # no point in trying if we are not registered
    my $workerid = $hosts->{$host}{workerid};
    return unless $workerid;

    # if there is already an existing web socket connection then don't do anything.
    # during setup there is none, and once established, finish hanler schedules automatic reconnect
    return if ($hosts->{$host}{ws});
    my $ua_url = $hosts->{$host}{url}->clone();
    if ($ua_url->scheme eq 'http') {
        $ua_url->scheme('ws');
    }
    else {
        $ua_url->scheme('wss');
    }
    $ua_url->path("ws/$workerid");
    log_debug("WEBSOCKET $ua_url") if $verbose;

    call_websocket($host, $ua_url);
}

sub call_websocket {
    my ($host, $ua_url) = @_;
    my $ua = $hosts->{$host}{ua};

    $ua->websocket(
        $ua_url => {'Sec-WebSocket-Extensions' => 'permessage-deflate'} => sub {
            my ($ua, $tx) = @_;
            if ($tx->is_websocket) {

                $tx->send(
                    {
                        json => {
                            type => 'worker_status',
                            (status => 'working', job => $job) x !!($job),
                            (status => 'free') x !!(!$job),
                        }});

                $hosts->{$host}{timers}{status} = add_timer(
                    "workerstatus-$host",
                    15,
                    sub {
                        log_debug("Sending worker status to $host");
                        $tx->send(
                            {
                                json => {
                                    type => 'worker_status',
                                    (status => 'working', job => $job) x !!($job),
                                    (status => 'free') x !!(!$job),
                                }});
                    });

                $tx->on(json => \&OpenQA::Worker::Commands::websocket_commands);
                $tx->on(
                    finish => sub {
                        remove_timer("workerstatus-$host");

                        $hosts->{$host}{timers}{setup_websocket}
                          = add_timer("setup_websocket-$host", 5, sub { setup_websocket($host) }, 1);
                        delete $ws_to_host->{$hosts->{$host}{ws}} if $ws_to_host->{$hosts->{$host}{ws}};
                        $hosts->{$host}{ws} = undef;
                    });
                $hosts->{$host}{ws} = $tx->max_websocket_size(10485760);
                $ws_to_host->{$hosts->{$host}{ws}} = $host;

                $hosts->{$host}{accepting_jobs} = 1;
            }
            else {
                delete $ws_to_host->{$hosts->{$host}{ws}} if ($hosts->{$host}{ws});
                $hosts->{$host}{ws} = undef;
                if (my $location_header = ($tx->completed ? $tx->res->headers->location : undef)) {
                    log_info("Following ws redirection to: $location_header");
                    call_websocket($host, $ua_url->parse($location_header));
                }
                else {
                    my $err = $tx->error;
                    if (defined $err) {
                        log_error "Unable to upgrade connection for host "
                          . "\"$hosts->{$host}{url}{host}\""
                          . " to WebSocket: "
                          . ($err->{code} ? $err->{code} : "[no code]")
                          . ". proxy_wstunnel enabled?";
                        if ($err->{code} && $err->{code} eq '404' && $hosts->{$host}{workerid}) {
                            # worker id suddenly not known anymore. Abort. If workerid
                            # is unset we already detected that in api_call
                            $hosts->{$host}{workerid} = undef;
                            OpenQA::Worker::Jobs::stop_job('api-failure');
                            $hosts->{$host}{timers}{register_worker}
                              = add_timer("register_worker-$host", 10, sub { register_worker($host) }, 1);
                            return;
                        }
                    }
                    # just retry in any error case - except when the worker ID isn't known
                    # anymore (hence return 3 lines above)
                    $hosts->{$host}{timers}{setup_websocket}
                      = add_timer("setup_websocket-$host", 10, sub { setup_websocket($host) }, 1);
                }
            }
        });
}

sub register_worker {
    my ($host, $dir, $testpoolserver) = @_;
    die unless $host;
    $hosts->{$host}{accepting_jobs} = 0;

    $worker_caps             = _get_capabilities;
    $worker_caps->{host}     = $hostname;
    $worker_caps->{instance} = $instance;
    if ($worker_settings->{WORKER_CLASS}) {
        $worker_caps->{worker_class} = $worker_settings->{WORKER_CLASS};
    }
    elsif ($cando{$worker_caps->{cpu_arch}}) {
        # TODO: check installed qemu and kvm?
        $worker_caps->{worker_class} = join(',', map { 'qemu_' . $_ } @{$cando{$worker_caps->{cpu_arch}}});
    }
    else {
        $worker_caps->{worker_class} = 'qemu_' . $worker_caps->{cpu_arch};
    }

    log_info("registering worker with openQA $host...");

    if (!$hosts->{$host}) {
        log_error "WebUI $host is unknown! - Should not happen but happened, exiting!";
        Mojo::IOLoop->stop;
        return;
    }
    # dir is set during initial registration call
    $hosts->{$host}{dir} = $dir if $dir;

    # test pool is from config, so it doesn't change
    $hosts->{$host}{testpoolserver} = $testpoolserver if $testpoolserver;

    # reset workerid
    $hosts->{$host}{workerid} = undef;

    # cleanup ws if active
    my $ws = $hosts->{$host}{ws};
    if ($ws) {
        $ws->finish();
    }

    # remove timers if set
    for my $t (keys %{$hosts->{$host}{timers}}) {
        my $t_id = $hosts->{$host}{timers}{$t};
        remove_timer($t_id) if $t_id;
        $hosts->{$host}{timers}{$t} = undef;
    }

    my $ua_url = $hosts->{$host}{url}->clone;
    my $ua     = $hosts->{$host}{ua};
    $ua_url->path('workers');
    $ua_url->query($worker_caps);
    my $tx = $ua->post($ua_url => json => $worker_caps);
    if ($tx->error) {
        my $err_code = $tx->error->{code};
        if ($err_code) {
            if ($err_code =~ /^4\d\d$/) {
                # don't retry when 4xx codes are returned. There is problem with scheduler
                log_error(
                    sprintf('ignoring server - server refused with code %s: %s', $tx->error->{code}, $tx->res->body));
                delete $hosts->{$host};
                Mojo::IOLoop->stop unless (scalar keys %$hosts);
            }
            else {
                log_warning(
                    sprintf('failed to register worker %s - %s:%s, retry in 10s', $host, $err_code, $tx->res->body));
                $hosts->{$host}{timers}{register_worker}
                  = add_timer("register_worker-$host", 10, sub { register_worker($host) }, 1);
            }
        }
        else {
            log_error("unable to connect to host $host, retry in 10s");
            $hosts->{$host}{timers}{register_worker}
              = add_timer("register_worker-$host", 10, sub { register_worker($host) }, 1);
        }
        return;
    }
    my $newid = $tx->res->json->{id};

    log_debug("new worker id within WebUI $host is $newid") if $verbose;
    $hosts->{$host}{workerid} = $newid;

    setup_websocket($host);
}

sub update_setup_status {
    my $workerid = verify_workerid();
    my $status = {setup => 1, worker_id => $workerid};
    api_call(
        'post',
        'jobs/' . $job->{id} . '/status',
        json     => {status => $status},
        callback => "no",
    );
    log_debug("[Worker#" . $workerid . "] Update status so job '" . $job->{id} . "' is not considered dead.");
}

sub verify_workerid {
    my ($host) = @_;
    $host //= $current_host;
    return unless $host;
    return $hosts->{$host}{workerid};
}

1;
