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

=pod

=head1 NAME

OpenQA::WebAPI::Controller::API::V1::Command

=head1 SYNOPSIS

  use OpenQA::WebAPI::Controller::API::V1::Command;

=head1 DESCRIPTION

Implements API methods for openQA commands.

=head1 METHODS

=over 4

=item create()

Sends a command to a worker. Receives the worker id and the command as arguments. Returns not
found if the worker cannot be found or a 200 status code and a JSON with an OK status of 1 on
success.

=back

=cut

sub create {
    my $self     = shift;
    my $workerid = $self->stash('workerid');
    my $command  = $self->param('command');
    my $worker   = $self->db->resultset('Workers')->find($workerid);

    if (!$worker) {
        log_warning("Trying to send command \'$command\' to unknown worker id $workerid");
        $self->reply->not_found;
    }

    # command is sent async, hence no error handling
    $worker->send_command(command => $command);
    $self->render(json => {ok => 1}, status => 200);
}

1;
# vim: set sw=4 et:
