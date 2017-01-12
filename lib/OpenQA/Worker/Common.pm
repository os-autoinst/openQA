# Copyright (C) 2015 SUSE Linux Products GmbH
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
use strict;
use warnings;
use feature 'state';

use Carp;
use POSIX 'uname';
use Mojo::URL;
use OpenQA::Client;

use base 'Exporter';
our @EXPORT = qw($job $workerid $verbose $instance $worker_settings $pooldir $nocleanup
  $worker_caps $testresults $openqa_url
  STATUS_UPDATES_SLOW STATUS_UPDATES_FAST
  add_timer remove_timer change_timer
  api_call verify_workerid register_worker ws_call);

# Exported variables
our $job;
our $workerid;
our $verbose  = 0;
our $instance = 'manual';
our $worker_settings;
our $pooldir;
our $nocleanup = 0;
our $testresults;
our $worker_caps;
our $openqa_url;

# package global variables
our $url;
our $ua;
my $ws;
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
    print "## adding timer $timer $timeout\n" if $verbose;
    my $timerid;
    if ($nonrecurring) {
        $timerid = Mojo::IOLoop->timer($timeout => $callback);
    }
    else {
        $timerid = Mojo::IOLoop->recurring($timeout => $callback);
        # store timerid for recurring global timers so we can stop them later
        $timers->{$timer} = [$timerid, $callback] if $timer;
  # there are still non-global host related timers, their $timerid is stored in respective $hosts->{$host}{timers} field
    }
    return $timerid;
}

sub remove_timer {
    my ($timer) = @_;
    return unless $timer;
    print "## removing timer $timer\n" if $verbose;
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
    print "## changing timer $timer\n" if $verbose;
    $callback = $timers->{$timer}->[1] unless $callback;
    remove_timer($timer);
    add_timer($timer, $newtimeout, $callback);
}

## prepare UA and URL for OpenQA-scheduler connection
sub api_init {
    my ($host_settings, $options) = @_;
    my @hosts = @{$host_settings->{HOSTS}};

    for my $host (@hosts) {
        my ($ua, $url);
        if ($host !~ '/') {
            $url = Mojo::URL->new();
            $url->host($host);
            $url->scheme('http');
        }
        else {
            $url = Mojo::URL->new($host);
        }

        my $openqa_url;
        # Mojo7 does not have authority anymore, can be removed once we say Mojo6- is no longer supported
        if ($url->can('authority')) {
            $openqa_url = $url->authority;
        }
        else {
            $openqa_url = $url->host_port;
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
            unless ($apikey && $apisecret) {
                die "API key and secret are needed for the worker connecting " . $url->host . "\n";
            }
            $ua->apikey($apikey);
            $ua->apisecret($apisecret);
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
    my $callback      = $args{callback};
    my $ignore_errors = $args{ignore_errors} // 0;
    my $tries         = $args{tries} // 3;

    die 'No worker id or webui host set!' unless verify_workerid($host);

    $method = uc $method;
    my $ua_url = $hosts->{$host}{url}->clone;
    my $ua     = $hosts->{$host}{ua};

    $ua_url->path($path =~ s/^\///r);
    $ua_url->query($params) if $params;

    print $method . " $ua_url\n" if $verbose;

    my @args = ($method, $ua_url);

    if ($json_data) {
        push @args, 'json', $json_data;
    }

    my $tx = $ua->build_tx(@args);
    my $cb;
    $cb = sub {
        my ($ua, $tx, $tries) = @_;
        my $res;
        if ($tx->success && $tx->success->json) {
            $res = $tx->success->json;
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
            $hosts->{$host}{workerid} = undef;
            $host = undef;
            add_timer('register_worker', 10, \&register_worker, 1);
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

    return;
}

sub ws_call {
    my ($type, $data) = @_;
    die 'Current host not set!' unless $current_host;
    my $res;
    # this call is also non blocking, result and image upload is handled by json handles
    print "WEBSOCKET: $type\n" if $verbose;
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
    # no point in trying if we are not registered
    return unless verify_workerid();

    # if there is an existing web socket connection wait until it finishes.
    if ($ws) {
        add_timer('setup_websocket', 2, \&setup_websocket, 1);
        return;
    }
    my $ua_url = $url->clone();
    if ($url->scheme eq 'http') {
        $ua_url->scheme('ws');
    }
    else {
        $ua_url->scheme('wss');
    }
    $ua_url->path("ws/$workerid");
    print "WEBSOCKET $ua_url\n" if $verbose;

    call_websocket($ua_url);
}

sub call_websocket;
sub call_websocket {
    my ($ua_url) = @_;

    $ua->websocket(
        $ua_url => {'Sec-WebSocket-Extensions' => 'permessage-deflate'} => sub {
            my ($ua, $tx) = @_;
            if ($tx->is_websocket) {
                # keep websocket connection busy
                add_timer('ws_keepalive', 5, sub { $tx->send({json => {type => 'ok'}}) });
                # check for new job immediately
                add_timer('check_job', 0, \&OpenQA::Worker::Jobs::check_job, 1);
                $tx->on(json => \&OpenQA::Worker::Commands::websocket_commands);
                $tx->on(
                    finish => sub {
                        add_timer('setup_websocket', 5, \&setup_websocket, 1);
                        remove_timer('ws_keepalive');
                        $ws = undef;
                    });
                $ws = $tx->max_websocket_size(10485760);
            }
            else {
                $ws = undef;
                if (my $location_header = ($tx->completed ? $tx->res->headers->location : undef)) {
                    print "Following ws redirection to: $location_header\n";
                    call_websocket($ua_url->parse($location_header));
                }
                else {
                    my $err = $tx->error;
                    if (defined $err) {
                        warn "Unable to upgrade connection to WebSocket: " . $err->{code} . ". proxy_wstunnel enabled?";
                        if ($err->{code} eq '404' && $workerid) {
                            # worker id suddenly not known anymore. Abort. If workerid
                            # is unset we already detected that in api_call
                            $workerid = undef;
                            OpenQA::Worker::Jobs::stop_job('api-failure');
                            add_timer('register_worker', 10, \&register_worker, 1);
                            return;
                        }
                    }
                    # just retry in any error case - except when the worker ID isn't known
                    # anymore (hence return 3 lines above)
                    add_timer('setup_websocket', 10, \&setup_websocket, 1);
                }
            }
        });
}

sub register_worker {
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

    print "registering worker ...\n" if $verbose;

    my $ua_url = $url->clone;
    $ua_url->path('workers');
    $ua_url->query($worker_caps);
    my $tx = $ua->post($ua_url => json => $worker_caps);
    unless ($tx->success && $tx->success->json) {
        if ($tx->error && $tx->error->{code} && $tx->error->{code} =~ /^4\d\d$/) {
            # don't retry when 4xx codes are returned. There is problem with scheduler
            printf "server refused with code %s: %s\n", $tx->error->{code}, $tx->res->body;
            Mojo::IOLoop->stop;
        }
        print "failed to register worker, retry ...\n" if $verbose;
        add_timer('register_worker', 10, \&register_worker, 1);
        return;
    }
    my $newid = $tx->success->json->{id};

    if ($ws && $workerid && $workerid != $newid) {
        # terminate websocked if our worker id changed
        $ws->finish() if $ws;
        $ws = undef;
    }
    $ENV{WORKERID} = $workerid = $newid;

    print "new worker id is $workerid...\n" if $verbose;

    if ($ws) {
        add_timer('check_job', 0, \&OpenQA::Worker::Jobs::check_job, 1);
    }
    else {
        add_timer('setup_websocket', 0, \&setup_websocket, 1);
    }
}

sub verify_workerid {
    return $workerid;
}

1;
