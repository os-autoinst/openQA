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

## WEBSOCKET commands
sub websocket_commands {
    my ($tx, $json) = @_;
    # result indicates response to our data
    if ($json->{'result'}) {
        # responses
        if ($json->{'known_images'}) {
            # response to update_status, filter known images
            OpenQA::Worker::Jobs::upload_images($json->{'known_images'});
        }
    }
    else {
        # requests
        my $type = $json->{'type'};
        my $jobid = $json->{'jobid'};
        if ($jobid) {
            if (!$job) {
                printf STDERR 'Received command for job %u, but we don not have any assigned. Ignoring!%s', $jobid, "\n";
                return;
            }
            elsif ($jobid ne $job->{'id'}) {
                printf STDERR 'Received command for different job id %u (our %u). Ignoring!%s', $jobid, $job->{'id'}, "\n";
                return;
            }
        }
        if ($type =~ m/quit|abort|cancel|obsolete/) {
            print "received command: $type" if $verbose;
            stop_job($type);
        }
        elsif ($type eq 'stop_waitforneedle') { # Plan: Enable interactive mode -- Now osautoinst decides what that means
            if (backend_running) {
                if (open(my $f, '>', "$pooldir/stop_waitforneedle")) {
                    close $f;
                    print "waitforneedle will be stopped\n" if $verbose;
                }
                else {
                    warn "can't stop waitforneedle: $!";
                }
            }
        }
        elsif ($type eq 'reload_needles_and_retry') { #
            if (backend_running) {
                if (open(my $f, '>', "$pooldir/reload_needles_and_retry")) {
                    close $f;
                    print "needles will be reloaded\n" if $verbose;
                }
                else {
                    warn "can't reload needles: $!";
                }
            }
        }
        elsif ($type eq 'enable_interactive_mode') {
            if (backend_running) {
                if (open(my $f, '>', "$pooldir/interactive_mode")) {
                    close $f;
                    print "interactive mode enabled\n" if $verbose;
                }
                else {
                    warn "can't enable interactive mode: $!";
                }
            }
        }
        elsif ($type eq 'disable_interactive_mode') {
            if (backend_running) {
                unlink("$pooldir/interactive_mode");
                print "interactive mode disabled\n" if $verbose;
            }
        }
        elsif ($type eq 'continue_waitforneedle') {
            if (backend_running) {
                unlink("$pooldir/stop_waitforneedle");
                print "continuing waitforneedle\n" if $verbose;
            }
        }
        elsif ($type eq 'livelog_start') {
            # change update_status timer if $job running
            if (backend_running) {
                unless ($OpenQA::Worker::Jobs::do_livelog) {
                    print "starting livelog\n" if $verbose;
                    change_timer('update_status', STATUS_UPDATES_FAST);
                }
                $OpenQA::Worker::Jobs::do_livelog += 1;
            }
        }
        elsif ($type eq 'livelog_stop') {
            # change update_status timer
            if (backend_running) {
                if ($OpenQA::Worker::Jobs::do_livelog) {
                    $OpenQA::Worker::Jobs::do_livelog -= 1;
                }
                else {
                    print "stopping livelog\n" if $verbose;
                    change_timer('update_status', STATUS_UPDATES_SLOW);
                }
            }
        }
        elsif ($type eq 'ok') {
            # ignore keepalives, but dont' report as unknown
        }
        elsif ($type eq 'job_available') {
            print "received job notification" if $verbose;
            if (!$job) {
                check_job
            }
        }
        else {
            print STDERR "got unknown command $type\n";
        }

    }
}

1;
