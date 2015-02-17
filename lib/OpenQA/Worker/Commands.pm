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

package OpenQA::Worker::Commands;
use strict;
use warnings;

use OpenQA::Worker::Common;
use OpenQA::Worker::Jobs;

## REST commands
# make sure only our local VMs access
sub check_authorized {
    my ($self) = @_;

    my $ip = $self->tx->remote_address;
    $self->app->log->debug("Request from $ip.");

    # accept only localhosts
    unless ($ip eq "127.0.0.1" || $ip eq "::1") {
        # forbid all non-localhost
        $self->render(text => "IP $ip is denied", status => 403);
        return;
    }

    # and when we have job
    unless ($job) {
        $self->render(text => 'not accepting backend commands without a job', status => 403);
        return;
    }

    return 1;
}

## Synchronization API
sub _mutex_call {
    my ($self, $action, $name) = @_;
    $self->render_later;
    my $res = api_call('get',"workers/$workerid/$action/$name", undef, undef, 1);
    if ($res) {
        $self->render(status => 200);
    }
    else {
        $self->render(status => 412);
    }
}

sub mutex_lock {
    my ($self) = @_;
    my $name = $self->param('name');
    _mutex_call($self, 'lock', $name);
}

sub mutex_unlock {
    my ($self) = @_;
    my $name = $self->param('name');
    _mutex_call($self, 'unlock', $name);
}

sub mutex_create {
    my ($self) = @_;
    my $name = $self->param('name');
    _mutex_call($self, 'createlock', $name);
}

## WEBSOCKET commands
sub websocket_commands {
    my ($tx, $msg) = @_;
    if ($msg =~ /^quit(\s*job_id=([0-9]*))?$/) { # quit_worker and reschedule the job
        my $job_id = $2;
        stop_job('quit', $job_id);
        Mojo::IOLoop->stop;
    }
    elsif ($msg =~ /^abort(\s*job_id=([0-9]*))?$/) { # the work is live and the job is rescheduled
        my $job_id = $2;
        stop_job('abort', $job_id);
    }
    elsif ($msg =~ /^cancel(\s*job_id=([0-9]*))?$/) { # The jobs is droped and the work is still alive
        my $job_id = $2;
        stop_job('cancel', $job_id);
    }
    elsif ($msg =~ /^obsolete(\s*job_id=([0-9]*))?$/) { # The jobs is droped and a new build job replaced it
        my $job_id = $2;
        stop_job('obsolete', $job_id);
    }
    elsif ($msg eq 'stop_waitforneedle') { # Plan: Enable interactive mode -- Now osautoinst decides what that means
        if (backend_running) {
            if (open(my $f, '>', "$pooldir/stop_waitforneedle")) {
                close $f;
                print "waitforneedle will be stopped";
            }
            else {
                warn "can't stop waitforneedle: $!";
            }
        }
    }
    elsif ($msg eq 'reload_needles_and_retry') { #
        if (backend_running) {
            if (open(my $f, '>', "$pooldir/reload_needles_and_retry")) {
                close $f;
                print "needles will be reloaded";
            }
            else {
                warn "can't reload needles: $!";
            }
        }
    }
    elsif ($msg eq 'enable_interactive_mode') {
        if (backend_running) {
            if (open(my $f, '>', "$pooldir/interactive_mode")) {
                close $f;
                print "interactive mode enabled\n";
            }
            else {
                warn "can't enable interactive mode: $!";
            }
        }
    }
    elsif ($msg eq 'disable_interactive_mode') {
        if (backend_running) {
            unlink("$pooldir/interactive_mode");
            print "interactive mode disabled\n";
        }
    }
    elsif ($msg eq 'continue_waitforneedle') {
        if (backend_running) {
            unlink("$pooldir/stop_waitforneedle");
            print "continuing waitforneedle";
        }
    }
    elsif ($msg eq 'livelog_start') {
        # change update_status timer if $job running
        if (backend_running) {
            change_timer('update_status', STATUS_UPDATES_FAST);
        }
    }
    elsif ($msg eq 'livelog_stop') {
        # change update_status timer
        if (backend_running) {
            change_timer('update_status', STATUS_UPDATES_SLOW);
        }
    }
    elsif ($msg eq 'ok') {
        # ignore keepalives, but dont' report as unknown
    }
    elsif ($msg eq 'job_available') {
        if (!$job) {
            check_job
        }
    }
    else {
        print STDERR "got unknown command $msg\n";
    }
}

1;
