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

package OpenQA::WebAPI::Command::gru::list;
use Mojo::Base 'Minion::Command::minion::job';

has description => 'List Gru jobs and more';
has usage       => sub { shift->extract_usage };

1;

=encoding utf8

=head1 NAME

OpenQA::WebAPI::Command::gru::list - Gru list command

=head1 SYNOPSIS

  Usage: APPLICATION gru list [OPTIONS] [IDS]

    script/openqa gru list
    script/openqa gru list 10023
    script/openqa gru list -w
    script/openqa gru list -w 23
    script/openqa gru list -s
    script/openqa gru list -f 10023
    script/openqa gru list -q important -t foo -t bar -S inactive
    script/openqa gru list -e foo -a '[23, "bar"]'
    script/openqa gru list -e foo -P 10023 -P 10024 -p 5 -q important
    script/openqa gru list -R -d 10 10023
    script/openqa gru list --remove 10023
    script/openqa gru list -L
    script/openqa gru list -L some_lock some_other_lock
    script/openqa gru list -b jobs -a '[12]'
    script/openqa gru list -b jobs -a '[12]' 23 24 25

  Options:
    -A, --attempts <number>     Number of times performing this new job will be
                                attempted, defaults to 1
    -a, --args <JSON array>     Arguments for new job or worker remote control
                                command in JSON format
    -b, --broadcast <command>   Broadcast remote control command to one or more
                                workers
    -d, --delay <seconds>       Delay new job for this many seconds
    -e, --enqueue <task>        New job to be enqueued
    -f, --foreground            Retry job in "minion_foreground" queue and
                                perform it right away in the foreground (very
                                useful for debugging)
    -H, --history               Show queue history
    -h, --help                  Show this summary of available options
        --home <path>           Path to home directory of your application,
                                defaults to the value of MOJO_HOME or
                                auto-detection
    -L, --locks                 List active named locks
    -l, --limit <number>        Number of jobs/workers to show when listing
                                them, defaults to 100
    -m, --mode <name>           Operating mode for your application, defaults to
                                the value of MOJO_MODE/PLACK_ENV or
                                "development"
    -o, --offset <number>       Number of jobs/workers to skip when listing
                                them, defaults to 0
    -P, --parent <id>           One or more jobs the new job depends on
    -p, --priority <number>     Priority of new job, defaults to 0
    -q, --queue <name>          Queue to put new job in, defaults to "default",
                                or list only jobs in these queues
    -R, --retry                 Retry job
        --remove                Remove job
    -S, --state <name>          List only jobs in these states
    -s, --stats                 Show queue statistics
    -t, --task <name>           List only jobs for these tasks
    -U, --unlock <name>         Release named lock
    -w, --workers               List workers instead of jobs, or show
                                information for a specific worker

=head1 DESCRIPTION

L<OpenQA::WebAPI::Command::gru::list> is a subclass of
L<Minion::Command::minion::job> that merely renames the command for backwards
compatibility.

=cut
