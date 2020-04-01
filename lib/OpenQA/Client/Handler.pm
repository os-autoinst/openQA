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

package OpenQA::Client::Handler;
use Mojo::Base 'Mojo::EventEmitter';

use OpenQA::Client;

has client => sub { OpenQA::Client->new };

has api_path => '/api/v1/';

sub _build_url {
    my ($self, $uri) = @_;

    # Check and make it Mojo::URL if wasn't already
    $self->client->base_url(Mojo::URL->new($self->client->base_url)) unless ref $self->client->base_url eq 'Mojo::URL';

    my $base_url   = $self->client->base_url->clone;
    my $is_api_url = $base_url->path->parts->[0];
    $uri = ($is_api_url && $is_api_url eq 'api') ? $uri : $self->api_path . $uri;
    $base_url->scheme('http') unless $base_url->scheme;    # Guard from no scheme in worker's conf files
    $base_url->path($uri);

    return $base_url;
}

sub _build_post { $_[0]->client->build_tx(POST => shift()->_build_url(+shift()) => form => +shift()) }


1;
