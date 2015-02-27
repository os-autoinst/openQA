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

package OpenQA::Worker;
use strict;
use warnings;

use Mojolicious::Lite;
use Mojo::Server::Daemon;
use Mojo::IOLoop;

use OpenQA::Client;
use OpenQA::Worker::Common;
use OpenQA::Worker::Commands;
use OpenQA::Worker::Pool qw/lockit clean_pool/;
use OpenQA::Worker::Jobs;

sub init {
    my ($worker_options, %options) = @_;
    $worker_settings = $worker_options;
    $instance = $options{'instance'} if defined $options{'instance'};
    $pooldir = OPENQA_BASE . '/pool/' . $instance;
    $nocleanup = $options{'no-cleanup'};
    $verbose = $options{'verbose'} if defined $options{'verbose'};

    OpenQA::Worker::Common::api_init(\%options);
    OpenQA::Worker::Engines::isotovideo::set_engine_exec($options{'isotovideo'}) if $options{'isotovideo'};
}

sub main {
    my $lockfd = lockit();

    $SIG{__DIE__} = sub { return if $^S; stop_job('quit'); exit(1); };

    clean_pool();

    ## register worker at startup
    verify_workerid;

    ## initial Mojo::IO timers
    add_timer('ws_keepalive', 5, \&OpenQA::Worker::Common::ws_keepalive);
    # backup check_job in case notification command does not get through
    add_timer('check_job', 10, \&check_job);

    # start event loop - this will block until stop is called
    Mojo::IOLoop->start;
    # cleanup on finish if necessary
    if ($job) {
        stop_job('quit');
    }
}

sub catch_exit{
    # send stop to event loop
    Mojo::IOLoop->stop;
}

$SIG{HUP} = \*catch_exit;
$SIG{TERM} = \*catch_exit;
$SIG{INT} = \*catch_exit;

1;
