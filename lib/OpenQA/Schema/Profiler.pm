# Copyright (C) 2015-2019 SUSE LLC
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

use OpenQA::Schema;
use OpenQA::Utils 'log_debug';
use Time::HiRes 'time';

sub query_start { shift->{start} = time() }

sub query_end {
    my ($self, $sql, @params) = @_;
    $sql = "$sql: " . join(', ', @params) if @params;
    my $elapsed = time() - $self->{start};
    log_debug(sprintf("[DBIC] Took %.8f seconds: %s", $elapsed, $sql));
}


sub enable_sql_debugging {
    my $class   = shift;
    my $storage = OpenQA::Schema->singleton->storage;
    $storage->debugobj($class->new);
    $storage->debug(1);
}

1;
