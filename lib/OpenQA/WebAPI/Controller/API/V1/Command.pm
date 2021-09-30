# Copyright 2015 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::API::V1::Command;
use Mojo::Base 'Mojolicious::Controller';

use OpenQA::Utils;

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
    my $self = shift;
    my $workerid = $self->stash('workerid');
    my $command = $self->param('command');
    my $worker = $self->schema->resultset('Workers')->find($workerid);

    if (!$worker) {
        log_warning("Trying to send command \'$command\' to unknown worker id $workerid");
        $self->reply->not_found;
    }

    # command is sent async, hence no error handling
    $worker->send_command(command => $command);
    $self->render(json => {ok => 1}, status => 200);
}

1;
