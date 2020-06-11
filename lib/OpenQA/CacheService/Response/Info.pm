# Copyright (C) 2019 SUSE LLC
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

package OpenQA::CacheService::Response::Info;
use Mojo::Base 'OpenQA::CacheService::Response';

sub available { !shift->error }

sub available_workers {
    my $self = shift;
    return undef unless $self->available;
    return undef unless my $data = $self->data;
    return $data->{active_workers} != 0 || $data->{inactive_workers} != 0;
}

sub availability_error {
    my $self = shift;
    if (my $err = $self->error) { return $err }
    return 'No workers active in the cache service' unless $self->available_workers;
    return undef;
}

1;
