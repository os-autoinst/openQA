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

package OpenQA::CacheService::Request::Asset;
use Mojo::Base 'OpenQA::CacheService::Request';

# See task OpenQA::Cache::Task::Asset
has [qw(id type asset host)];
has task => 'cache_asset';

sub lock {
    my $self = shift;

    # Generate same lock for asset/host
    return join('.', map { $self->$_ } qw(asset host));
}

sub to_array {
    my $self = shift;
    return [$self->id, $self->type, $self->asset, $self->host];
}

1;
