# Copyright (C) 2015-2016 SUSE LLC
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

package db_profiler;

use strict;
use base 'DBIx::Class::Storage::Statistics';

use Time::HiRes 'time';

my $start;
my $msg;

sub query_start {
    my $self   = shift();
    my $sql    = shift();
    my @params = @_;

    $msg = "$sql: " . join(', ', @params);
    $start = time();
}

sub query_end {
    my $self   = shift();
    my $sql    = shift();
    my @params = @_;

    my $elapsed = time() - $start;
    $self->print(sprintf("[DBIx debug] Took %.8f seconds executed: %s.\n", $elapsed, $msg));
    $start = undef;
    $msg   = '';
}


sub enable_sql_debugging {
    my ($app) = @_;
    my $storage = $app->schema->storage;
    $storage->debugobj(new db_profiler());
    $storage->debugfh(MojoDebugHandle->new($app->log));
    $storage->debug(1);
}

package MojoDebugHandle;

sub new {
    my ($class, $log) = @_;

    return bless {log => $log}, $class;
}

sub print {
    my ($self, $line) = @_;
    chop $line;
    $self->{log}->debug($line);
}


1;
