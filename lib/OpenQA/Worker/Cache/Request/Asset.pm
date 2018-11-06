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

package OpenQA::Worker::Cache::Request::Asset;

use Mojo::Base 'OpenQA::Worker::Cache::Request';

# See task OpenQA::Cache::Task::Asset
my @FIELDS = qw(id type asset host);
has [@FIELDS];
has task => 'cache_asset';

sub lock {
    my $self = shift;
    # Generate same lock for asset/host
    join('.', map { $self->$_ } qw(asset host));
}
sub to_hash { {id => $_[0]->id, type => $_[0]->type, asset => $_[0]->asset, host => $_[0]->host} }
sub to_array { $_[0]->id, $_[0]->type, $_[0]->asset, $_[0]->host }

!!42;
