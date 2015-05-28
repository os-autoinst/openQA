# Copyright (C) 2015 SUSE Linux GmbH
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

package OpenQA;

use strict;
use warnings;

use OpenQA::Scheduler;
use OpenQA::WebSockets;
use OpenQA::WebAPI;

use POSIX ':sys_wait_h';

my %pids;

sub _run {
    my ($component, $start_routine) = @_;
    my $child = fork();
    if ($child) {
        $pids{$component} = $child;
        print STDERR "$component started with pid $child\n";
    }
    else {
        $start_routine->();
        exit;
    }
}

sub _stopAll {
    for (keys %pids) {
        my $pid = $pids{$_};
        my $ret;
        print STDERR "stopping $_ with pid $pid\n";
        kill('TERM', $pid);
        for my $i (1 .. 5) {
            $ret = waitpid($pid, WNOHANG);
            last if ($ret == $pid);
            sleep 1;
        }
        next if ($ret == $pid);
        kill("KILL", $pid);
    }
    %pids = ();
}

sub run {
    # if ARGV is not daemon||prefork => don't start the whole stack
    my $deamonize = $ARGV[0] =~ /daemon|prefork/;
    if ($deamonize) {
        # start Mojo::IOLoop @ Scheduler
        _run('scheduler', \&OpenQA::Scheduler::run);
        # start Mojo::Lite @ WebSockets
        _run('websockets', \&OpenQA::WebSockets::run);
        # start Mojolicious @ WebAPI
        _run('webapi', \&OpenQA::WebAPI::run);

        $SIG{ALRM} = \&_stopAll;
        $SIG{TERM} = \&_stopAll;
        $SIG{INT}  = \&_stopAll;
        $SIG{HUP}  = \&_stopAll;

        # wait for any children to finish
        waitpid(-1, 0);
        # and stop the rest if not already stopped
        _stopAll;
    }
    else {
        OpenQA::WebAPI::run;
    }
}

1;
# vim: set sw=4 et:
