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
use strict;
use warnings;
use feature 'state';

use Carp;
use POSIX 'uname';
use Mojo::URL;
use OpenQA::Client;
use OpenQA::Utils qw(log_error log_debug log_warning log_info), qw(feature_scaling rand_range logistic_map_steps);
use Scalar::Util 'looks_like_number';
use Config::IniFiles;
use List::Util 'max';

use base 'Exporter';
our @EXPORT = qw($job $instance $worker_settings $pooldir $nocleanup
  $hosts $ws_to_host $current_host
  $worker_caps $testresults update_setup_status
  STATUS_UPDATES_SLOW STATUS_UPDATES_FAST
  add_timer remove_timer change_timer get_timer
  api_call verify_workerid register_worker);

# Exported variables
our $job;
our $current_error;
our $instance = 'manual';
our $worker_settings;
our $pooldir;
our $nocleanup = 0;
our $testresults;
our $worker_caps;
our $isotovideo_interface_version = 0;
# package global variables
# HASHREF with structure
# {hostname => {url => Mojo::URL, ua => OpenQA::Client, ws => Mojo::Transaction::WebSockets}, workerid => uint}
our $hosts;
our $ws_to_host;

# undef unless working on job - then contains hostname of webui we are working for
our $current_host;

my ($sysname, $hostname, $release, $version, $machine) = POSIX::uname();

# global constants
use OpenQA::Constants qw(WEBSOCKET_API_VERSION MAX_TIMER MIN_TIMER);

# local constants
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
    log_debug("## adding timer $timer $timeout");
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
    log_debug("## removing timer $timer");
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
    log_debug("## changing timer $timer");
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


        my ($apikey, $apisecret) = ($options->{apikey}, $options->{apisecret});
        $ua = OpenQA::Client->new(
            api       => $url->host,
            apikey    => $apikey,
            apisecret => $apisecret
        );
        $ua->base_url($url);

        # Relative paths are appended to the existing one
        $url->path('/api/v1/');

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

    my $host      = $args{host} // $current_host;
    my $params    = $args{params};
    my $json_data = $args{json};
    my $callback  = $args{callback} // sub { };
    my $tries     = $args{tries} // 3;

    # if set ignore errors completely and don't retry
    my $ignore_errors = $args{ignore_errors} // 0;

    # if set apply usual error handling (retry attempts) but treat failure as non-critical
    my $non_critical = $args{non_critical} // 0;

    do { OpenQA::Worker::Jobs::_reset_state(); die 'No worker id or webui host set!'; } unless verify_workerid($host);

    # build URL
    $method = uc $method;
    my $ua_url = $hosts->{$host}{url}->clone;
    my $ua     = $hosts->{$host}{ua};
    $ua_url->path($path);
    $ua_url->query($params) if $params;
    # adjust port for separate daemons like the liveviewhandler
    # (see also makeWsUrlAbsolute() in openqa.js)
    if (my $service_port_delta = $args{service_port_delta}) {
        if (my $webui_port = $ua_url->port()) {
            $ua_url->port($webui_port + $service_port_delta);
        }
    }
    log_debug("$method $ua_url");

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

        # format error message for log
        if ($tx->res && $tx->res->json) {
            # JSON API might provide error message
            $msg = $tx->res->json->{error};
        }
        $msg //= $err->{message};
        if ($err->{code}) {
            $msg = "$err->{code} response: $msg";
            if ($err->{code} == 404) {
                # don't retry on 404 errors (in this case we can't expect different
                # results on further attempts)
                $tries = 0;
            }
        }
        else {
            $msg = "Connection error: $msg";
        }
        log_error($msg . " (remaining tries: $tries)");

        # handle critical error when no more attempts remain
        if ($tries <= 0 && !$non_critical) {
            # abort the current job, we're in trouble - but keep running to grab the next
            OpenQA::Worker::Jobs::stop_job('api-failure', undef, $host);
            $callback->();
            return;
        }

        # handle non-critical error when no more attempts remain
        if ($tries <= 0) {
            $callback->();
            return;
        }

        # retry in 5 seconds if there are remaining attempts
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

sub _get_capabilities {
    my $caps = {};
    my $query_cmd;

    if ($worker_settings->{ARCH}) {
        $caps->{cpu_arch} = $worker_settings->{ARCH};
    }
    else {
        open(my $LSCPU, "-|", "LC_ALL=C lscpu");
        for my $line (<$LSCPU>) {
            chomp $line;
            if ($line =~ m/Model name:\s+(.+)$/) {
                $caps->{cpu_modelname} = $1;
            }
            if ($line =~ m/Architecture:\s+(.+)$/) {
                $caps->{cpu_arch} = $1;
            }
            if ($line =~ m/CPU op-mode\(s\):\s+(.+)$/) {
                $caps->{cpu_opmode} = $1;
            }
        }
        close($LSCPU);
    }
    open(my $MEMINFO, "<", "/proc/meminfo");
    for my $line (<$MEMINFO>) {
        chomp $line;
        if ($line =~ m/MemTotal:\s+(\d+).+kB/) {
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
    log_debug("WEBSOCKET $ua_url");

    call_websocket($host, $ua_url);
}

# checks whether the worker is available
sub check_availability {
    # clear previously detected errors (which might be gone)
    $OpenQA::Worker::Common::current_error = undef;

    # check whether the cache service is available if caching enabled
    if ($worker_settings->{CACHEDIRECTORY}) {
        if ($OpenQA::Worker::Common::current_error = OpenQA::Worker::Cache::Client->new->availability_error) {
            log_debug('Worker cache not available: ' . $OpenQA::Worker::Common::current_error);
        }
        else {
            log_debug('Worker cache seems available.');
        }
    }
}

sub send_status {
    my ($tx) = @_;

    my $has_job = defined $job && ref($job) eq 'HASH' && exists $job->{id};
    check_availability() unless $has_job;

    my %status_message = (type => 'worker_status');
    if ($has_job) {
        $status_message{status} = 'working';
        $status_message{job}    = $job;
    }
    elsif ($current_error) {
        $status_message{status} = 'broken';
        $status_message{reason} = $current_error;
    }
    else {
        $status_message{status} = 'free';
    }
    $tx->send({json => \%status_message});
}

sub calculate_status_timer {
    my ($hosts, $host) = @_;
    my $i    = $hosts->{$host}{workerid}   ? $hosts->{$host}{workerid}   : looks_like_number($instance) ? $instance : 1;
    my $imax = $hosts->{$host}{population} ? $hosts->{$host}{population} : 1;
    my $scale_factor = $imax;
    my $steps        = 215;
    my $r            = 3.81199961;

    # my $scale_factor = 4;
    # my $scale_factor =  (MAX_TIMER - MIN_TIMER)/MIN_TIMER;
    # log_debug("I: $i population: $imax scale_factor: $scale_factor");

    # XXX: we are using now fixed values, to stick with a
    #      predictable behavior but random intervals
    #      seems to work as well.
    # my $steps = int(rand_range(2, 120));
    # my $r = rand_range(3.20, 3.88);

    my $population = feature_scaling($i, $imax, 0, 1);
    my $status_timer
      = abs(feature_scaling(logistic_map_steps($steps, $r, $population) * $scale_factor, $imax, MIN_TIMER, MAX_TIMER));
    $status_timer = $status_timer > MIN_TIMER
      && $status_timer < MAX_TIMER ? $status_timer : $status_timer > MAX_TIMER ? MAX_TIMER : MIN_TIMER;
    return sprintf("%.2f", $status_timer);
}

sub call_websocket {
    my ($host, $ua_url) = @_;
    my $ua           = $hosts->{$host}{ua};
    my $status_timer = calculate_status_timer($hosts, $host, $instance, $worker_settings);

    log_debug("worker_status timer time window: $status_timer");
    $ua->websocket(
        $ua_url => {'Sec-WebSocket-Extensions' => 'permessage-deflate'} => sub {
            my ($ua, $tx) = @_;
            if ($tx->is_websocket) {
                $hosts->{$host}{timers}{status} = add_timer(
                    "workerstatus-$host",
                    $status_timer,
                    sub {
                        log_debug("Sending worker status to $host (workerstatus timer)");
                        send_status($tx);
                    });

                $tx->on(json => \&OpenQA::Worker::Commands::websocket_commands);
                $tx->on(
                    finish => sub {
                        my (undef, $code, $reason) = @_;
                        log_debug("Connection turned off from $host - $code : "
                              . (defined $reason ? $reason : "Not specified"));
                        remove_timer("workerstatus-$host");

                        $hosts->{$host}{timers}{setup_websocket}
                          = add_timer("setup_websocket-$host", 5, sub { setup_websocket($host) }, 1);
                        delete $ws_to_host->{$hosts->{$host}{ws}} if $ws_to_host->{$hosts->{$host}{ws}};
                        $hosts->{$host}{ws} = undef;
                    });
                $hosts->{$host}{ws} = $tx->max_websocket_size(10485760);
                $ws_to_host->{$hosts->{$host}{ws}} = $host;

                $hosts->{$host}{accepting_jobs} = 1;

                # send status immediately
                send_status($tx);
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
                          . ". Apache modules proxy_wstunnel and rewrite enabled?";

                        if ($err->{code} && $err->{code} eq '404' && $hosts->{$host}{workerid}) {
                            # worker id suddenly not known anymore. Abort. If workerid
                            # is unset we already detected that in api_call
                            $hosts->{$host}{workerid} = undef;
                            OpenQA::Worker::Jobs::stop_job('api-failure', undef, $host);
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
    my ($host, $dir, $testpoolserver, $shared_cache) = @_;
    die unless $host;
    $hosts->{$host}{accepting_jobs} = 0;

    $worker_caps                                 = _get_capabilities;
    $worker_caps->{host}                         = $hostname;
    $worker_caps->{instance}                     = $instance;
    $worker_caps->{websocket_api_version}        = WEBSOCKET_API_VERSION;
    $worker_caps->{isotovideo_interface_version} = $isotovideo_interface_version;
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

    log_info(
"registering worker $hostname version $isotovideo_interface_version with openQA $host using protocol version [@{[WEBSOCKET_API_VERSION]}]"
    );

    if (!$hosts->{$host}) {
        log_error "WebUI $host is unknown! - Should not happen but happened, exiting!";
        Mojo::IOLoop->stop;
        return;
    }
    # dir is set during initial registration call
    $hosts->{$host}{dir} = $dir if $dir;

    # test pool is from config, so it doesn't change
    $hosts->{$host}{testpoolserver} = $testpoolserver if $testpoolserver;
    $hosts->{$host}{shared_cache}   = $shared_cache   if $shared_cache;

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

    log_debug("new worker id within WebUI $host is $newid");
    $hosts->{$host}{workerid} = $newid;

    setup_websocket($host);
}

sub update_setup_status {
    my $workerid = verify_workerid();
    my $status   = {setup => 1, worker_id => $workerid};
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

sub read_worker_config {
    my ($instance, $host) = @_;
    my $worker_dir = $ENV{OPENQA_CONFIG} || '/etc/openqa';
    my $worker_ini = $worker_dir . '/workers.ini';

    my $cfg;
    if (-e $worker_ini || !$ENV{OPENQA_USE_DEFAULTS}) {
        $cfg = Config::IniFiles->new(-file => $worker_dir . '/workers.ini');
    }

    my $sets = {};
    for my $section ('global', $instance) {
        if ($cfg && $cfg->SectionExists($section)) {
            for my $set ($cfg->Parameters($section)) {
                $sets->{uc $set} = $cfg->val($section, $set);
            }
        }
    }
    # use separate set as we may not want to advertise other host confiuration to the world in job settings
    my $host_settings;
    $host ||= $sets->{HOST} ||= 'localhost';
    delete $sets->{HOST};
    my @hosts = split ' ', $host;
    for my $section (@hosts) {
        if ($cfg && $cfg->SectionExists($section)) {
            for my $set ($cfg->Parameters($section)) {
                $host_settings->{$section}{uc $set} = $cfg->val($section, $set);
            }
        }
        else {
            $host_settings->{$section} = {};
        }
    }
    $host_settings->{HOSTS} = \@hosts;

    return $sets, $host_settings;
}

1;
