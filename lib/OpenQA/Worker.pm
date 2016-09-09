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
    $instance        = $options{instance} if defined $options{instance};
    $pooldir         = OPENQA_BASE . '/pool/' . $instance;
    $nocleanup       = $options{"no-cleanup"};
    $verbose         = $options{verbose} if defined $options{verbose};

    OpenQA::Worker::Common::api_init(\%options);
    OpenQA::Worker::Engines::isotovideo::set_engine_exec($options{isotovideo}) if $options{isotovideo};
}

sub main {
    my $lockfd = lockit();

    clean_pool();

    ## register worker at startup
    add_timer('register_worker', 0, \&OpenQA::Worker::Common::register_worker, 1);

    # start event loop - this will block until stop is called
    Mojo::IOLoop->start;

    return 0;
}

sub catch_exit {
    my ($sig) = @_;
    print STDERR "quit due to signal $sig\n";
    if ($job && !$OpenQA::Worker::Jobs::stop_job_running) {
        Mojo::IOLoop->next_tick(
            sub {
                stop_job('quit');
                Mojo::IOLoop->stop;
            });
    }
    else {
        Mojo::IOLoop->stop;
    }
}

$SIG{HUP}  = \*catch_exit;
$SIG{TERM} = \*catch_exit;
$SIG{INT}  = \*catch_exit;

1;
