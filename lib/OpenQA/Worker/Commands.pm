# Copyright (C) 2015-17 SUSE LLC
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
use 5.012;
use warnings;

use OpenQA::Utils qw(log_error log_warning log_debug);
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
            log_warning('Received WS message without type!');
            return;
        }
        my $jobid = $json->{jobid} // '';
        my $joburl;
        my $host = $ws_to_host->{$tx};
        my $ua   = Mojo::UserAgent->new;
        if ($jobid) {
            if (!$job) {
                log_warning("Received command $type for job $jobid, but we do not have any assigned. Ignoring!");
                return;
            }
            elsif ($jobid ne $job->{id}) {
                log_warning("Received command $type for different job id $jobid (our " . $job->{id} . '). Ignoring!');
                return;
            }
            elsif (!$current_host) {
                die 'Job ids match but current host not set';
            }
            elsif ($current_host ne $host) {
                log_warning(
                    "Received message from different host ($host) than we are working with ($current_host). Ignoring");
            }
        }
        if ($job) {
            $joburl = $job->{URL};
        }
        if ($type =~ m/quit|abort|cancel|obsolete/) {
            log_debug("received command: $type") if $verbose;
            stop_job($type);
        }
        elsif ($type eq 'stop_waitforneedle') {
            if (backend_running) {
                $ua->post("$joburl/isotovideo/stop_waitforneedle");
                log_debug('stop_waitforneedle triggered') if $verbose;
                ws_call('property_change', {waitforneedle => 1});
            }
        }
        elsif ($type eq 'reload_needles_and_retry') {
            if (backend_running) {
                $ua->post("$joburl/isotovideo/reload_needles");
                log_debug('needles will be reloaded') if $verbose;
            }
        }
        elsif ($type eq 'enable_interactive_mode') {
            if (backend_running) {
                $ua->post("$joburl/isotovideo/interactive?state=1");
                log_debug('interactive mode enabled') if $verbose;
                ws_call('property_change', {interactive_mode => 1});
            }
        }
        elsif ($type eq 'disable_interactive_mode') {
            if (backend_running) {
                $ua->post("$joburl/isotovideo/interactive?state=0");
                log_debug('interactive mode disabled') if $verbose;
                ws_call('property_change', {interactive_mode => 0});
            }
        }
        elsif ($type eq 'continue_waitforneedle') {
            if (backend_running) {
                $ua->post("$joburl/isotovideo/continue_waitforneedle");
                log_debug('waitforneedle will continue') if $verbose;
                ws_call('property_change', {waitforneedle => 0});
            }
        }
        elsif ($type eq 'livelog_start') {
            # change update_status timer if $job running
            if (backend_running) {
                OpenQA::Worker::Jobs::start_livelog();
                log_debug('Starting livelog') if $verbose;
                change_timer('update_status', STATUS_UPDATES_FAST);
            }
        }
        elsif ($type eq 'livelog_stop') {
            # change update_status timer
            if (backend_running) {
                log_debug('Stopping livelog') if $verbose;
                OpenQA::Worker::Jobs::stop_livelog();
                unless (OpenQA::Worker::Jobs::has_logviewers()) {
                    change_timer('update_status', STATUS_UPDATES_SLOW);
                }
            }
        }
        elsif ($type eq 'ok') {
            # ignore keepalives, but dont' report as unknown
        }
        elsif ($type eq 'job_available') {
            log_debug('received job notification') if $verbose;
            if (!$job) {
                Mojo::IOLoop->next_tick(sub { check_job($host) });
            }
        }
        else {
            log_error("got unknown command $type");
        }

    }
}

1;
