# Copyright (C) 2019-2021 SUSE LLC
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
use Mojo::Base 'OpenQA::CacheService::Response', -signatures;

sub available { !shift->has_error }

sub available_workers ($self) {
    return undef unless $self->available;
    return undef unless my $data = $self->data;
    return $data->{active_workers} != 0 || $data->{inactive_workers} != 0;
}

sub inactive_jobs_exceeded ($self) {
    return undef if $self->max_inactive_jobs < 0;
    return undef unless my $data = $self->data;
    return undef unless $data->{inactive_jobs};
    return $data->{inactive_jobs} > $self->max_inactive_jobs;
}

sub availability_error ($self) {
    return $self->error if $self->has_error;
    return 'No workers active in the cache service' unless $self->available_workers;
    return 'Cache service queue already full (' . $self->max_inactive_jobs . ')' if $self->inactive_jobs_exceeded;
    return undef;
}

1;
