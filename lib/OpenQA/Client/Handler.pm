# Copyright (C) 2018 SUSE Linux Products GmbH
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

package OpenQA::Client::Handler;
use Mojo::Base 'Mojo::EventEmitter';
use OpenQA::Client;

has client => sub { OpenQA::Client->new };

has api_path => '/api/v1/';

sub _build_post {
    my $self     = shift;
    my $base_url = $self->client->base_url;
    my $uri      = shift;
    my $form     = shift;

    my $ua_url = $base_url->clone;
    $ua_url->path($uri);

    return $self->client->build_tx(POST => $ua_url => form => $form);
}

1;
