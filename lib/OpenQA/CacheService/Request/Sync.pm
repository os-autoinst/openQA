# Copyright 2018-2019 SUSE LLC
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

package OpenQA::CacheService::Request::Sync;
use Mojo::Base 'OpenQA::CacheService::Request';

# See task OpenQA::Cache::Task::Sync
has [qw(from to)];
has task => 'cache_tests';

sub lock {
    my $self = shift;
    return join('.', map { $self->$_ } qw(from to));
}

sub to_array {
    my $self = shift;
    return [$self->from, $self->to];
}

1;
