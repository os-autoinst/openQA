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

package OpenQA::WebSockets::Controller::API;
use Mojo::Base 'Mojolicious::Controller';

use OpenQA::WebSockets::Server;

sub is_worker_connected {
    my $self      = shift;
    my $worker_id = $self->param('worker_id');
    my $bool      = OpenQA::WebSockets::Server::ws_is_worker_connected($worker_id);
    $self->render(json => {connected => $bool ? \1 : \0});
}

1;
