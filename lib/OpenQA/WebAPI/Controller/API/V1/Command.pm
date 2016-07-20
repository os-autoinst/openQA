# Copyright (C) 2015 SUSE Linux GmbH
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

package OpenQA::WebAPI::Controller::API::V1::Command;
use Mojo::Base 'Mojolicious::Controller';
use OpenQA::Utils;
use OpenQA::IPC;
use Try::Tiny;

sub create {
    my $self     = shift;
    my $workerid = $self->stash('workerid');
    my $command  = $self->param('command');
    my $worker   = $self->db->resultset('Workers')->find($workerid);

    if (!$worker) {
        log_warning("Trying to send command \'$command\' to unknown worker id $workerid");
        $self->reply->not_found;
    }

    my $res = $worker->send_command(command => $command);

    if ($res && $res > 1) {
        $self->reply(status => 200);
    }
    else {
        $self->reply(json => {error => 'Worker not found by WebSockets server'}, status => 404);
    }
}

1;
# vim: set sw=4 et:
