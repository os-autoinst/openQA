# Copyright 2015-2019 SUSE LLC
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

package OpenQA::Schema::Profiler;

use strict;
use warnings;

use base 'DBIx::Class::Storage::Statistics';

use OpenQA::Log 'log_debug';
use Time::HiRes qw(gettimeofday tv_interval);

sub query_start { shift->{start} = [gettimeofday()] }

sub query_end {
    my ($self, $sql, @params) = @_;
    $sql = "$sql: " . join(', ', @params) if @params;
    my $elapsed = tv_interval($self->{start}, [gettimeofday()]);
    log_debug(sprintf("[DBIC] Took %.8f seconds: %s", $elapsed, $sql));
}

# We need to override print because DBIx::Class::Storage::Statistics::print()
# is called for txn_begin ('BEGIN WORK') etc., which writes to the default
# $sorage->debugfh, while log_debug() writes to the specified log filehandle.
# To make sure all messages land in the same logfile, we call log_debug() here
# like in query_end()
sub print {
    my ($self, $msg) = @_;
    chomp $msg;

    log_debug(sprintf("[DBIC] %s", $msg));
}

sub enable_sql_debugging {
    my $class = shift;

    # Defer loading to prevent the worker from triggering a migration
    require OpenQA::Schema;
    my $storage = OpenQA::Schema->singleton->storage;
    $storage->debugobj($class->new);
    $storage->debug(1);
}

1;

=encoding utf8

=head1 NAME

OpenQA::Schema::Profiler - Logs timing information for OpenQA::Schema SQL queries

=head1 SYNOPSIS

  use OpenQA::Schema::Profiler;

  OpenQA::Schema::Profiler->enable_sql_debugging;

=head1 DESCRIPTION

L<OpenQA::Schema::Profiler> collects statistics from L<OpenQA::Schema> about SQL
queries that have been executed. It is usually activated with the
C<OPENQA_SQL_DEBUG> environment variable. This is quite expensive and should
therefore only be used during development.

=cut
