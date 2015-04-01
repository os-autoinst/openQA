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
use POSIX qw/uname/;

use base qw/Exporter/;
our @EXPORT = qw/$job $workerid $verbose $instance $worker_settings $pooldir $nocleanup $worker_caps $testresults $openqa_url
  OPENQA_BASE OPENQA_SHARE ISO_DIR HDD_DIR STATUS_UPDATES_SLOW STATUS_UPDATES_FAST
  add_timer remove_timer change_timer
  api_call verify_workerid register_worker ws_call/;

# Exported variables
our $job;
our $workerid;
our $verbose = 0;
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
use constant OPENQA_BASE => '/var/lib/openqa';
use constant OPENQA_SHARE => OPENQA_BASE . '/share';
use constant ASSET_DIR => OPENQA_SHARE . '/factory';
use constant {
    ISO_DIR => ASSET_DIR . '/iso',
    HDD_DIR => ASSET_DIR . '/hdd',
};
use constant {
    STATUS_UPDATES_SLOW => 10,
    STATUS_UPDATES_FAST => 0.5,
};

# the template noted what architecture are known
my %cando = (
    'i586'    => ['i586'],
    'i686'    => [ 'i686', 'i586' ],
    'x86_64'  => [ 'x86_64', 'i686', 'i586' ],

    'ppc'     => ['ppc'],
    'ppc64'   => [ 'ppc64le', 'ppc64', 'ppc' ],
    'ppc64le' => [ 'ppc64le', 'ppc64', 'ppc' ],

    's390'    => ['s390'],
    's390x'   => [ 's390x', 's390' ],

    'aarch64' => ['aarch64'],
);

## Mojo timers ids
my $timers = {
    # register worker with web ui
    'register_worker' => undef,
    # set up websocket connection
    'setup_websocket' => undef,
    # check for commands from scheduler
    'ws_keepalive' => undef,
    # check for new job
    'check_job'       => undef,
    # update status of running job
    'update_status'   => undef,
    # check for crashed backend and its running status
    'check_backend'   => undef,
    # trigger stop_job if running for > $max_job_time
    'job_timeout'     => undef,
    # app call retry
    'api_call'        => undef,
};

sub add_timer {
    my ($timer, $timeout, $callback, $nonrecurring) = @_;
    die "must specify timer\n" unless $timer;
    die "must specify callback\n" unless $callback && ref $callback eq 'CODE';
    # skip if timer already defined, but not if one shot timer (avoid the need to call remove_timer for nonrecurring)
    return if ($timers->{$timer} && !$nonrecurring);
    print "## adding timer $timer $timeout\n" if $verbose;
    my $timerid;
    if ($nonrecurring) {
        $timerid = Mojo::IOLoop->timer(
            $timeout => sub {
                # automatically clean %$timers for single shot timers
                remove_timer($timer);
                $callback->();
            }
        );
    }
    else {
        $timerid = Mojo::IOLoop->recurring( $timeout => $callback);
    }
    $timers->{$timer} = [$timerid, $callback];
    return $timerid;
}

sub remove_timer {
    my ($timer) = @_;
    return unless ($timer && $timers->{$timer});
    print "## removing timer $timer\n" if $verbose;
    Mojo::IOLoop->remove($timers->{$timer}->[0]);
    $timers->{$timer} = undef;
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
    my ($options) = @_;
    my $host = $options->{host};

    if ($host !~ '/') {
        $url = Mojo::URL->new();
        $url->host($host);
        $url->scheme('http');
    }
    else {
        $url = Mojo::URL->new($host);
    }
    $openqa_url = $url->authority;
    # Relative paths are appended to the existing one
    $url->path('/api/v1/');

    my ($apikey, $apisecret) = ($options->{apikey}, $options->{apisecret});
    $ua = OpenQA::Client->new(
        api => $url->host,
        apikey => $apikey,
        apisecret => $apisecret
    );

    unless ($ua->apikey && $ua->apisecret) {
        unless ($apikey && $apisecret) {
            die "API key and secret are needed for the worker connecting " . $url->host . "\n";
        }
        $ua->apikey($apikey);
        $ua->apisecret($apisecret);
    }
}

# send a command to openQA API
sub api_call {
    my ($method, $path, $params, $json_data, $ignore_errors) = @_;
    state $call_running;

    return undef unless verify_workerid();

    if ($call_running) {
        # quit immediately
        Mojo::IOLoop->next_tick(sub {} );
        Mojo::IOLoop->stop;
        Carp::croak "recursive api_call is fatal";
        return;
    }

    $call_running = 1;

    $method = uc $method;
    my $ua_url = $url->clone;

    $ua_url->path($path =~ s/^\///r);
    $ua_url->query($params) if $params;

    print $method . " $ua_url\n" if $verbose;

    my @args = ($method, $ua_url);

    if ($json_data) {
        push @args, 'json', $json_data;
    }

    my $res;
    my $done = 0;

    my $tx = $ua->build_tx(@args);
    my $cb;
    $cb = sub {
        my ($ua, $tx, $tries) = @_;
        if ($tx->success && $tx->success->json) {
            $res = $tx->success->json;
            $done = 1;
            return;
        }
        elsif ($ignore_errors) {
            $done = 1;
            return;
        }
        --$tries;
        my $err = $tx->error;
        my $msg = $err->{code} ? "$tries: $err->{code} response: $err->{message}" : "$tries: Connection error: $err->{message}";
        Carp::carp $msg;
        if (!$tries) {
            # abort the current job, we're in trouble - but keep running to grab the next
            remove_timer('setup_websocket');
            $workerid = undef;
            OpenQA::Worker::Jobs::stop_job('api-failure');
            add_timer('register_worker', 10, \&register_worker, 1);
            $done = 1;
            return;
        }
        $tx = $ua->build_tx(@args);
        add_timer(
            'api_call',
            5,
            sub {
                $ua->start($tx => sub { $cb->(@_, $tries) });
            },
            1
        );
    };
    $ua->start($tx => sub { $cb->(@_, 3) });

    # This ugly. we need to "block" here so enter ioloop recursively
    while(!$done && Mojo::IOLoop->is_running) {
        Mojo::IOLoop->one_tick;
    }

    $call_running = 0;

    return $res;
}

sub ws_call {
    my ($type, $data) = @_;
    my $res;
    # this call is also non blocking, result and image upload is handled by json handles
    print "WEBSOCKET: $type\n" if $verbose;
    $ws->send({json => {type => $type, jobid => $job->{id} || '', data => $data}});
}

sub _get_capabilities {
    my $caps = {};
    my $query_cmd;

    if ($worker_settings->{ARCH}) {
        $caps->{cpu_arch} = $worker_settings->{ARCH};
    }
    else {
        open(LSCPU, "LC_ALL=C lscpu|");
        while (<LSCPU>) {
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
        close(LSCPU);
    }
    open(MEMINFO, "/proc/meminfo");
    while (<MEMINFO>) {
        chomp;
        if (m/MemTotal:\s+(\d+).+kB/) {
            my $mem_max = $1 ? $1 : '';
            $caps->{mem_max} = int($mem_max/1024) if $mem_max;
        }
    }
    close(MEMINFO);
    return $caps;
}

sub setup_websocket {
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
    $ua_url->path("workers/$workerid/ws");
    print "WEBSOCKET $ua_url\n" if $verbose;
    $ua->websocket(
        $ua_url => {'Sec-WebSocket-Extensions' => 'permessage-deflate'} => sub {
            my ($ua, $tx) = @_;
            if ($tx->is_websocket) {
                # keep websocket connection busy
                add_timer('ws_keepalive', 5, sub { $tx->send({json => { type => 'ok'}}) });
                # check for new job immediately
                add_timer('check_job', 0, \&OpenQA::Worker::Jobs::check_job, 1 );
                $tx->on(json => \&OpenQA::Worker::Commands::websocket_commands);
                $tx->on(
                    finish => sub {
                        add_timer('setup_websocket', 5, \&setup_websocket, 1);
                        remove_timer('ws_keepalive');
                        $ws = undef;
                    }
                );
                $ws = $tx->max_websocket_size(10485760);
            }
            else {
                my $err = $tx->error;
                $ws = undef;
                warn "Unable to upgrade connection to WebSocket: ".$err->{code}.". proxy_wstunnel enabled?" if defined $err;
                if ($err->{code} eq '404') {
                    # worker id suddenly not known anymore. Abort. If workerid
                    # is unset we already detected that in api_call
                    if ($workerid) {
                        $workerid = undef;
                        OpenQA::Worker::Jobs::stop_job('api-failure');
                        add_timer('register_worker', 10, \&register_worker, 1);
                    }
                }
                else {
                    add_timer('setup_websocket', 10, \&setup_websocket, 1);
                }
            }
        }
    );
}

sub register_worker {
    $worker_caps = _get_capabilities;
    $worker_caps->{host} = $hostname;
    $worker_caps->{instance} = $instance;
    if ($worker_settings->{WORKER_CLASS}) {
        $worker_caps->{worker_class} =$worker_settings->{WORKER_CLASS};
    }
    elsif ($cando{$worker_caps->{cpu_arch}}) {
        # TODO: check installed qemu and kvm?
        $worker_caps->{worker_class} = join(',', map { 'qemu_'.$_ } @{$cando{$worker_caps->{cpu_arch}}});
    }
    else {
        $worker_caps->{worker_class} = 'qemu_'.$worker_caps->{cpu_arch};
    }

    print "registering worker ...\n" if $verbose;

    my $ua_url = $url->clone;
    $ua_url->path('workers');
    $ua_url->query($worker_caps);
    my $tx = $ua->post($ua_url => json => $worker_caps);
    unless ($tx->success && $tx->success->json) {
        if ($tx->error && $tx->error->{code} && $tx->error->{code} =~ /^4\d\d$/) {
            die sprintf "server refused with code %s: %s\n", $tx->error->{code}, $tx->res->body;
        }
        print "failed to register worker, retry ...\n" if $verbose;
        add_timer('register_worker', 10, \&register_worker, 1);
        return;
    }
    my $newid = $tx->success->json->{id};

    if ($workerid && $workerid != $newid) {
        # terminate websocked if our worker id changed
        $ws->finish() if $ws;
    }
    $ENV{WORKERID} = $workerid = $newid;

    print "new worker id is $workerid...\n" if $verbose;

    add_timer('setup_websocket', 0, \&setup_websocket, 1);
}

sub verify_workerid {
    return $workerid;
}

1;
