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

package OpenQA::Worker::Cache::Task;

use Mojo::Base 'Mojolicious::Plugin';

has client => sub { OpenQA::Worker::Cache::Client->new };

sub _dequeue { shift->client->_dequeue_lock(pop) }
sub _gen_guard_name { join('.', shift->client->session_token, pop) }

!!42;
