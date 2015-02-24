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

package OpenQA::Worker::Engines::isotovideo;
use strict;
use warnings;

use OpenQA::Worker::Common;
use OpenQA::Utils qw//;

use POSIX qw/:sys_wait_h strftime SIGTERM SIGKILL uname/;
use JSON qw/to_json/;
use Fcntl;

my $isotovideo = "/usr/bin/isotovideo";
my $workerpid;

require Exporter;
our (@ISA, @EXPORT);
@ISA = qw(Exporter);
@EXPORT = qw/engine_workit engine_check/;

sub set_engine_exec {
    my ($path) = @_;
    $isotovideo = $path;
}

sub _kill($) {
    my ($pid) = @_;
    my $n = kill(SIGTERM, $pid);
    for (my $i = 0; $n && $i < 5; ++$i) {
        sleep 1;
        $n = kill(SIGTERM, $pid);
    }
    if ($n) {
        warn "pid $pid didn't die, sending KILL";
        kill(SIGKILL, $pid);
    }
}

sub _save_vars($) {
    my $vars = shift;
    die "cannot get environment variables!\n" unless $vars;
    my $fn = $pooldir . "/vars.json";
    unlink "$pooldir/vars.json" if -e "$pooldir/vars.json";
    open( my $fd, ">", $fn ) or die "can not write vars.json: $!\n";
    fcntl( $fd, F_SETLKW, pack( 'ssqql', F_WRLCK, 0, 0, 0, $$ ) ) or die "cannot lock vars.json: $!\n";
    truncate( $fd, 0 ) or die "cannot truncate vars.json: $!\n";

    print $fd to_json( \%$vars, { pretty => 1 } );
    close($fd);
}

sub engine_workit($){
    my $job = shift;

    # XXX: this should come from the worker table. Only included
    # here for convenience when looking at the pool of
    # debugging.
    for my $i (qw/QEMUPORT VNC OPENQA_HOSTNAME/) {
        $job->{settings}->{$i} = $ENV{$i};
    }
    if (open(my $fh, '>', 'job.json')) {
        print $fh to_json($job, { pretty => 1 });
        close $fh;
    }

    # always set proper TAPDEV for os-autoinst when using tap network mode
    # ensure MAC addresses differ, tap devices may be bridged together
    # and allow MAC addresses for more than 256 workers (up to 65535)
    if (($job->{'settings'}->{'NICTYPE'}//'') eq 'tap') {
        $job->{'settings'}->{'TAPDEV'} = 'tap' . ($instance - 1);
        $job->{'settings'}->{'NICMAC'} = sprintf("52:54:00:12:%02x:%02x", int($instance / 256), $instance % 256);
    }

    if (my $iso = $job->{'settings'}->{'ISO'}) {
        $iso = join('/', ISO_DIR, $iso);
        unless (-e $iso) {
            warn "$iso does not exist!\n";
            return;
        }
        $job->{'settings'}->{'ISO'} = $iso;
    }

    my $nd = $job->{'settings'}->{'NUMDISKS'} || 2;
    for my $i (1..$nd) {
        my $hdd = $job->{'settings'}->{"HDD_$i"} || undef;
        if ($hdd) {
            $hdd = join('/', HDD_DIR, $hdd);
            unless (-e $hdd) {
                warn "$hdd does not exist!\n";
                return;
            }
            $job->{'settings'}->{"HDD_$i"} = $hdd;
        }
    }

    my %vars = (OPENQA_URL => $openqa_url);
    while (my ($k, $v) = each %{$job->{'settings'}}) {
        print "setting $k=$v\n" if $verbose;
        $vars{$k} = $v;
    }
    $vars{CASEDIR} = OpenQA::Utils::testcasedir($vars{DISTRI}, $vars{VERSION});
    _save_vars(\%vars);

    # create tmpdir for qemu to write here
    my $tmpdir = "$pooldir/tmp";
    mkdir($tmpdir) unless (-d $tmpdir);

    my $child = fork();
    die "failed to fork: $!\n" unless defined $child;

    unless ($child) {
        $ENV{'TMPDIR'} = $tmpdir;
        printf "$$: WORKING %d\n", $job->{'id'};
        if (open(my $log, '>', "autoinst-log.txt")) {
            print $log "+++ worker notes +++\n";
            printf $log "start time: %s\n", strftime("%F %T", gmtime);
            my ($sysname, $hostname, $release, $version, $machine) = POSIX::uname();
            printf $log "running on $hostname:%d ($sysname $release $version $machine)\n", $instance;
            close($log);
        }
        open STDOUT, ">>", "autoinst-log.txt";
        open STDERR, ">&STDOUT";
        exec "$isotovideo", '-d';
        die "exec failed: $!\n";
    }
    else {
        $workerpid = $child;
        return { pid => $child };
    }

}

sub engine_check {
    # abort job if backend crashed and reschedule it
    if(-e "$pooldir/backend.crashed") {
        unlink("$pooldir/backend.crashed");
        print STDERR "backend crashed ...\n";
        if (open(my $fh, '<', "$pooldir/qemu.pid")) {
            local $/;
            my $pid = <$fh>;
            close $fh;
            if ($pid =~ /(\d+)/) {
                print STDERR "killing qemu $1\n";
                _kill($1);
            }
        }
        if (open(my $fh, '<', "$pooldir/os-autoinst.pid")) {
            local $/;
            my $pid = <$fh>;
            close $fh;
            if ($pid =~ /(\d+)/) {
                print STDERR "killing os-autoinst $1\n";
                _kill($1);
            }
        }
        return 'crashed';
    }

    # check if the worker is still running
    my $pid = waitpid($workerpid, WNOHANG);
    if ($verbose) {
        printf "waitpid %d returned %d\n", $workerpid, $pid;
    }

    if ($pid == $workerpid) {
        if ($?) {
            warn "child $pid died with exit status $?\n";
            return 'died';
        }
        else {
            return 'done';
        }
    }
    return;
}
