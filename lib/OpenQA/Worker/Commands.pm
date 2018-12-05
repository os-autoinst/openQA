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

use 5.018;
use strict;
use warnings;

use OpenQA::Utils qw(log_error log_warning log_debug add_log_channel remove_log_channel);
use OpenQA::Worker::Common;
use OpenQA::Worker::Jobs;
use POSIX ':sys_wait_h';
use OpenQA::Worker::Engines::isotovideo;
use Data::Dump 'pp';

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
        if (!$json->{type}) {
            log_warning('Received WS message without type! ' . pp($json));
            return;
        }
        my $type  = $json->{type};
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
                log_warning('Job ids match but current host not set');
                return unless $type eq "scheduler_abort";
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
            log_debug("received command: $type");
            stop_job($type);
        }
        elsif ($type eq 'info') {
            $hosts->{$host}{population} = $json->{population} if $json->{population};
            log_debug("Population for $host is " . $hosts->{$host}{population});
            change_timer("workerstatus-$host", OpenQA::Worker::Common::calculate_status_timer($hosts, $host));
        }
        elsif ($type eq 'livelog_start') {
            # change update_status timer if $job running
            if (backend_running) {
                OpenQA::Worker::Jobs::start_livelog();
                log_debug('Starting livelog');
                change_timer('update_status', STATUS_UPDATES_FAST);
            }
        }
        elsif ($type eq 'livelog_stop') {
            # change update_status timer
            if (backend_running) {
                log_debug('Stopping livelog');
                OpenQA::Worker::Jobs::stop_livelog();
                unless (OpenQA::Worker::Jobs::has_logviewers()) {
                    change_timer('update_status', STATUS_UPDATES_SLOW);
                }
            }
        }
        elsif ($type eq 'developer_session_start') {
            OpenQA::Worker::Jobs::report_developer_session_started();
        }
        elsif ($type eq 'grab_job') {
            state $check_job_running;
            state $job_in_progress;

            # refuse new jobs if caching is not available (this will leave the job in assigned state)
            my $cache_client = OpenQA::Worker::Cache::Client->new;
            my $error        = $cache_client->availability_error;
            if ($error) {
                log_debug("Refusing 'grab_job', caching not available: $error");
                return;
            }

            # refuse new jobs if already busy (this will leave the job in assigned state)
            my $job = $json->{job};
            if ($job_in_progress) {
                log_debug("Refusing 'grab_job', we are already performing another job");
                return;
            }

            return unless $job;
            return if $check_job_running->{$host};

            $job_in_progress = 1;
            $check_job_running->{$host} = 1;
            Mojo::IOLoop->singleton->once(
                "stop_job" => sub {
                    log_debug("Build finished, setting us free to pick up new jobs",);
                    $job_in_progress = 0;
                    $check_job_running->{$host} = 0;
                });

            if ($job && $job->{id}) {
                $OpenQA::Worker::Common::job = $job;
                remove_log_channel('autoinst');
                remove_log_channel('worker');
                add_log_channel('autoinst', path => 'autoinst-log.txt', level => 'debug');
                add_log_channel(
                    'worker',
                    path    => 'worker-log.txt',
                    level   => $worker_settings->{LOG_LEVEL} // 'info',
                    default => 'append'
                );

                log_debug("Job " . $job->{id} . " scheduled for next cycle");
                Mojo::IOLoop->singleton->once(
                    "start_job" => sub {
                        $OpenQA::Worker::Common::job->{state} = "running";
                        OpenQA::Worker::Common::send_status($tx);
                        log_debug("Sent worker status to $host (start_job)");
                    });
                $tx->send({json => {type => "accepted", jobid => $job->{id}}} => sub { start_job($host); });
            }
            else {
                $job_in_progress = 0;
                $check_job_running->{$host} = 0;
            }
        }
        elsif ($type eq 'incompatible') {
            log_error("The worker is running an incompatible version");
            Mojo::IOLoop->singleton->stop_gracefully;
        }
        else {
            log_error("got unknown command $type");
        }

    }
}

1;
