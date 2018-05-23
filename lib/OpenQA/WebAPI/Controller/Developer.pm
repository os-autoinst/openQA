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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package OpenQA::WebAPI::Controller::Developer;
use strict;
use Mojo::Base 'Mojolicious::Controller';
use OpenQA::Utils;
use OpenQA::Schema::Result::Jobs;

# returns the isotovideo web socket URL for the given job or undef if not available
sub determine_web_socket_url {
    my ($job) = @_;

    return unless $job->state eq OpenQA::Schema::Result::Jobs::RUNNING;
    my $worker    = $job->assigned_worker             or return;
    my $job_token = $worker->get_property('JOBTOKEN') or return;
    my $host      = $worker->host                     or return;
    my $port      = ($worker->get_property('QEMUPORT') // 20012) + 1;
    # FIXME: don't hardcode port
    return "ws://$host:$port/$job_token/ws";
}

sub ws_console {
    my ($self) = @_;

    # find job
    return $self->reply->not_found if (!defined $self->param('testid'));
    my $jobs = $self->app->schema->resultset('Jobs');
    my $job = $jobs->search({id => $self->param('testid')})->first;
    return $self->reply->not_found unless $job;
    $self->stash(job => $job);

    $self->stash(ws_url => (determine_web_socket_url($job) // ''));
    return $self->render;
}

1;
# vim: set sw=4 et:
