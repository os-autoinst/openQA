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

package OpenQA::CacheService::Response::Status;
use Mojo::Base 'OpenQA::CacheService::Response';

sub is_downloading { (shift->data->{status} // '') eq 'downloading' }
sub is_processed   { (shift->data->{status} // '') eq 'processed' }

sub output {
    my $self = shift;
    return $self->has_error ? $self->error : $self->data->{output};
}

sub result { shift->data->{result} }

1;
