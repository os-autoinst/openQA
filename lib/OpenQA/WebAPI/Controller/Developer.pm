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
use Try::Tiny;
use Mojo::URL;
use Mojo::Base 'Mojolicious::Controller';
use OpenQA::Utils;
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;

# returns the isotovideo command server web socket URL for the given job or undef if not available
sub determine_os_autoinst_web_socket_url {
    my ($job) = @_;
    return unless $job->state eq OpenQA::Jobs::Constants::RUNNING;

    # determine job token and host from worker
    my $worker    = $job->assigned_worker             or return;
    my $job_token = $worker->get_property('JOBTOKEN') or return;
    my $host      = $worker->host                     or return;

    # determine port
    my $cmd_srv_raw_url = $worker->get_property('CMD_SRV_URL') or return;
    my $cmd_srv_url     = Mojo::URL->new($cmd_srv_raw_url);
    my $port            = $cmd_srv_url->port() or return;
    return "ws://$host:$port/$job_token/ws";
}

# returns the url to the own web socket server started via openqa-livehandler
sub determine_web_ui_web_socket_url {
    my ($job_id) = @_;
    return "liveviewhandler/tests/$job_id/developer/ws-proxy";
}

sub get_ws_status_only_url {
    my ($job_id) = @_;
    return "liveviewhandler/tests/$job_id/developer/ws-proxy/status";
}

# returns the job for the currently processed request
sub find_current_job {
    my ($self) = @_;

    my $test_id = $self->param('testid') or return;
    my $jobs = $self->app->schema->resultset('Jobs');
    return $jobs->search({id => $test_id})->first;
}

# serves a simple HTML/JavaScript page to connect either
#  1. directly from browser to os-autoinst command server
#  2. or to connect via ws_proxy route defined in LiveViewHandler.pm
# (option 1. is default; specify query parameter 'proxy=1' for 2.)
sub ws_console {
    my ($self) = @_;

    my $job = $self->find_current_job() or return $self->reply->not_found;
    my $use_proxy = $self->param('proxy') // 0;

    # determine web socket URL
    my $ws_url = determine_os_autoinst_web_socket_url($job);
    if ($use_proxy) {
        $ws_url = $ws_url ? determine_web_ui_web_socket_url($job->id) : undef;
    }

    $self->stash(job       => $job);
    $self->stash(ws_url    => ($ws_url // ''));
    $self->stash(use_proxy => $use_proxy);
    return $self->render;
}

1;
# vim: set sw=4 et:
