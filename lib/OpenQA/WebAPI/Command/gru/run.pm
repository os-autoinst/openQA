# Copyright (C) 2018 SUSE LLC
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

package OpenQA::WebAPI::Command::gru::run;
use Mojo::Base 'Minion::Command::minion::worker';

use Mojo::Util 'getopt';
use OpenQA::WebAPI::GruJob;

has description => 'Start Gru worker';
has usage       => sub { shift->extract_usage };

sub run {
    my ($self, @args) = @_;

    getopt \@args, 'o|oneshot' => \(my $oneshot);

    my $minion = $self->app->minion;
    $minion->on(
        worker => sub {
            my ($minion, $worker) = @_;

            # Only one job can run at a time for now (until all Gru tasks are parallelism safe)
            $worker->status->{jobs} = 1;

            $worker->on(
                dequeue => sub {
                    my ($worker, $job) = @_;

                    # Reblessing the job is fine for now, but in the future it would be nice
                    # to use a role instead
                    bless $job, 'OpenQA::WebAPI::GruJob';
                });
        });

    if   ($oneshot) { $minion->perform_jobs }
    else            { $self->SUPER::run(@args) }
}

1;

=encoding utf8

=head1 NAME

OpenQA::WebAPI::Command::gru::run - Gru run command

=head1 SYNOPSIS

  Usage: APPLICATION gru run [OPTIONS]

    script/openqa gru run
    script/openqa gru run -o
    script/openqa gru run -m production -I 15 -C 5 -R 3600 -j 10
    script/openqa gru run -q important -q default

  Options:
    -C, --command-interval <seconds>     Worker remote control command interval,
                                         defaults to 10
    -D, dequeue-timeout <seconds>        Maximum amount of time to wait for
                                         jobs, defaults to 5
    -h, --help                           Show this summary of available options
        --home <path>                    Path to home directory of your
                                         application, defaults to the value of
                                         MOJO_HOME or auto-detection
    -I, --heartbeat-interval <seconds>   Heartbeat interval, defaults to 300
    -j, --jobs <number>                  Maximum number of jobs to perform
                                         parallel in forked worker processes,
                                         defaults to 4
    -m, --mode <name>                    Operating mode for your application,
                                         defaults to the value of
                                         MOJO_MODE/PLACK_ENV or "development"
    -o, --oneshot                        Perform all currently enqueued jobs and
                                         then exit
    -q, --queue <name>                   One or more queues to get jobs from,
                                         defaults to "default"
    -R, --repair-interval <seconds>      Repair interval, up to half of this
                                         value can be subtracted randomly to
                                         make sure not all workers repair at the
                                         same time, defaults to 21600 (6 hours)


=head1 DESCRIPTION

L<OpenQA::WebAPI::Command::gru::run> is a subclass of
L<Minion::Command::minion::worker> that adds Gru features with
L<OpenQA::WebAPI::GruJob>.

=cut
