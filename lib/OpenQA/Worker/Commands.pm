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
    if ($json->{result}) {
        # responses
        if ($json->{known_images}) {
            # response to update_status, filter known images
            OpenQA::Worker::Jobs::upload_images($json->{known_images});
        }
    }
    else {
        # requests
        my $type = $json->{type};
        if (!$type) {
            printf STDERR 'Received WS message without type!';
            return;
        }
        my $jobid = $json->{jobid} // '';
        my $joburl;
        my $ua = Mojo::UserAgent->new;
        if ($jobid) {
            if (!$job) {
                printf STDERR 'Received command %s for job %u, but we do not have any assigned. Ignoring!%s', $type, $jobid, "\n";
                return;
            }
            elsif ($jobid ne $job->{id}) {
                printf STDERR 'Received command %s for different job id %u (our %u). Ignoring!%s', $type, $jobid, $job->{id}, "\n";
                return;
            }
        }
        if ($job) {
            $joburl = $job->{URL};
        }
        if ($type =~ m/quit|abort|cancel|obsolete/) {
            print "received command: $type" if $verbose;
            stop_job($type);
        }
        elsif ($type eq 'stop_waitforneedle') {
            if (backend_running) {
                $ua->post("$joburl/isotovideo/stop_waitforneedle");
                print "stop_waitforneedle triggered\n" if $verbose;
                ws_call('property_change', {waitforneedle => 1});
            }
        }
        elsif ($type eq 'reload_needles_and_retry') {
            if (backend_running) {
                $ua->post("$joburl/isotovideo/reload_needles");
                print "needles will be reloaded\n" if $verbose;
            }
        }
        elsif ($type eq 'enable_interactive_mode') {
            if (backend_running) {
                $ua->post("$joburl/isotovideo/interactive?state=1");
                print "interactive mode enabled\n" if $verbose;
                ws_call('property_change', {interactive_mode => 1});
            }
        }
        elsif ($type eq 'disable_interactive_mode') {
            if (backend_running) {
                $ua->post("$joburl/isotovideo/interactive?state=0");
                print "interactive mode disabled\n" if $verbose;
                ws_call('property_change', {interactive_mode => 0});
            }
        }
        elsif ($type eq 'continue_waitforneedle') {
            if (backend_running) {
                $ua->post("$joburl/isotovideo/continue_waitforneedle");
                print "waitforneedle will continue\n" if $verbose;
                ws_call('property_change', {waitforneedle => 0});
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
                unless ($OpenQA::Worker::Jobs::do_livelog) {
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
                check_job;
            }
        }
        else {
            print STDERR "got unknown command $type\n";
        }

    }
}

1;
