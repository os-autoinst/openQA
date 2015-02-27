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

use Carp;
use POSIX qw/uname/;

use base qw/Exporter/;
our @EXPORT = qw/$job $workerid $verbose $instance $worker_settings $pooldir $nocleanup $worker_caps $testresults $openqa_url
  OPENQA_BASE OPENQA_SHARE RESULTS_DIR ISO_DIR HDD_DIR STATUS_UPDATES_SLOW STATUS_UPDATES_FAST
  add_timer remove_timer change_timer
  api_call verify_workerid/;

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
my $url;
my $ua;
my $ws;
my ($sysname, $hostname, $release, $version, $machine) = POSIX::uname();

# global constants
use constant OPENQA_BASE => '/var/lib/openqa';
use constant OPENQA_SHARE => OPENQA_BASE . '/share';
use constant ASSET_DIR => OPENQA_SHARE . '/factory';
use constant {
    ISO_DIR => ASSET_DIR . '/iso',
    HDD_DIR => ASSET_DIR . '/hdd',
    RESULTS_DIR => OPENQA_SHARE . '/testresults'
};
use constant {
    STATUS_UPDATES_SLOW => 5,
    STATUS_UPDATES_FAST => 0.5,
};

## Mojo timers ids
my $timers = {
    # check for commands from scheduler
    'ws_keepalive' => undef,
    # check for new job
    'check_job'       => undef,
    # update status of running job
    'update_status'   => undef,
    # check for crashed backend and its running status
    'check_backend'   => undef,
    # trigger stop_job if running for > $max_job_time
    'job_timeout'     => undef
};

sub add_timer {
    my ($timer, $timeout, $callback, $nonrecurring) = @_;
    return unless ($timer && $timeout && $callback);
    return if ($timers->{$timer});
    print "## adding timer $timer\n" if $verbose;
    my $timerid;
    if ($nonrecurring) {
        $timerid = Mojo::IOLoop->timer( $timeout => $callback);
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
    my $host = $options->{'host'};

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

    my ($apikey, $apisecret) = ($options->{'apikey'}, $options->{'apisecret'});
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
    $method = lc $method;
    my $ua_url = $url->clone;

    $ua_url->path($path =~ s/^\///r);
    $ua_url->query($params) if $params;

    my $tries = 3;
    while (1) {
        print uc($method) . " $ua_url\n" if $verbose;
        my $tx;
        if ($json_data) {
            $tx = $ua->$method($ua_url => json => $json_data);
        }
        else {
            $tx = $ua->$method($ua_url);
        }
        if ($tx->success) {
            return $tx->success->json;
        }
        elsif ($ignore_errors) {
            return;
        }
        --$tries;
        my ($err, $code) = $tx->error;
        my $msg = $code ? "$tries: $code response: $err" : "$tries: Connection error: $err->{message}";
        carp "$msg";
        if (!$tries) {
	  # abort the current job, we're in trouble - but keep running to grab the next
	  # this lives in Jobs.pm - this is recursive use?
            stop_job('api-failure');
            return;
        }
        sleep 5;
    }
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

sub verify_workerid {
    if (!$workerid) {
        $worker_caps = _get_capabilities;
        $worker_caps->{host} = $hostname;
        $worker_caps->{instance} = $instance;
        $worker_caps->{backend} = $worker_settings->{'BACKEND'};

        my $res = api_call('post','workers', $worker_caps);
        return unless $res;
        $ENV{'WORKERID'} = $workerid = $res->{id};
        # recreate WebSocket connection, our id may have changed
        if ($ws) {
            $ws->finish;
            $ws = undef;
        }
    }
    if (!$ws) {
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
            $ua_url => sub {
                my ($ua, $tx) = @_;
                if ($tx->is_websocket) {
                    $ws = $tx;
                    $tx->on(message => \&OpenQA::Worker::Commands::websocket_commands);
                    $tx->on(
                        finish => sub {
                            print "closing websocket connection\n" if $verbose;
                            $ws = undef;
                        }
                    );
                }
                else {
                    my $err = $tx->error;
                    carp "Unable to upgrade connection to WebSocket: ".$err->{code}.". proxy_wstunnel enabled?" if defined $err;
                    $ws = undef;
                }
            }
        );
    }
    return $workerid;
}

sub ws_keepalive {
    #send ok keepalive so WebSocket connection is not inactive
    return unless $ws;
    $ws->send('ok');
}
1;
