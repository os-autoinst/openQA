# Copyright (C) 2016 SUSE LLC
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

package OpenQA::FakeApp;
use Mojo::Log;
use Mojo::Home;
use strict;
use warnings;
use Mojo::Base -base;
use Sys::Hostname;
use File::Spec::Functions 'catfile';
use Mojo::File 'path';

has config => sub { {} };

has log => sub { Mojo::Log->new(handle => \*STDOUT, level => "debug"); };

has home => sub { Mojo::Home->new($ENV{MOJO_HOME} || '/') };

has mode => 'production';

has log_name => 'scheduler';

has level => 'debug';

has instance => undef;

has log_dir => undef;

has schema => sub { OpenQA::Schema::connect_db() };

sub setup_log {
    my ($self) = @_;
    if ($self->log_dir) {
        # So each worker from each host get it's own log (as the folder can be shared). Hopefully the machine hostname
        # is already sanitized. Otherwise we need to check
        my $logfile
          = catfile($self->log_dir, hostname() . (defined $self->instance ? "-${\$self->instance}" : '') . ".log");

        $self->log->handle(path($logfile)->open('>>'));

        $self->log->path($logfile);
    }

    $self->log->format(
        sub {
            my ($time, $level, @lines) = @_;
            return '[' . localtime($time) . "] [${\$self->log_name}:$level] " . join "\n", @lines, '';
        });

    $self->log->level($self->level);
}


sub emit_event {
    my ($self, $event, $data) = @_;
    # nothing to see here, move along
}

1;
