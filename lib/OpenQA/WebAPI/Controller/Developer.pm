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

package OpenQA::WebAPI::Controller::Developer;
use Mojo::Base 'Mojolicious::Controller';

use OpenQA::Utils 'determine_web_ui_web_socket_url';

# serves a simple HTML/JavaScript page to connect either
#  1. directly from browser to os-autoinst command server
#  2. or to connect via ws_proxy route defined in LiveViewHandler.pm
# (option 1. is default; specify query parameter 'proxy=1' for 2.)
sub ws_console {
    my $self = shift;

    return $self->reply->not_found unless my $job = $self->find_current_job;
    my $use_proxy = $self->param('proxy') // 0;

    # determine web socket URL
    my $ws_url = $self->determine_os_autoinst_web_socket_url($job);
    $ws_url = $ws_url ? determine_web_ui_web_socket_url($job->id) : undef if $use_proxy;

    return $self->render(job => $job, ws_url => ($ws_url // ''), use_proxy => $use_proxy);
}

1;
