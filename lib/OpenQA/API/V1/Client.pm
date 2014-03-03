# Copyright (C) 2014 SUSE Linux Products GmbH
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

package OpenQA::API::V1::Client;

use Mojo::Base 'Mojo::UserAgent';
use Mojo::Util 'hmac_sha1_sum';
use Carp;

has 'key';
has 'secret';

sub new {
    my $self = shift->SUPER::new;
    my %args = @_;

    for my $i (qw/key secret/) {
        next unless $args{$i};
        $self->$i($args{$i});
    }

    $self->on(start => sub {
            $self->_add_auth_headers(@_);
        });

    return $self;
}

sub _add_auth_headers {
    my ($self, $ua, $tx) = @_;

    unless ($self->secret && $self->key) {
        carp "missing secret and/or key";
        return;
    }

    my $timestamp = time;
    my %headers = (
        Accept => 'application/json',
        'X-API-Key' => $self->key,
        'X-API-Microtime' => $timestamp,
        'X-API-Hash' => hmac_sha1_sum($self->_path_query($tx).$timestamp, $self->secret),
    );

    while (my ($k, $v) = each %headers) {
        $tx->req->headers->header($k, $v);
    }
}

sub _path_query {
    my $self  = shift;
    my $url = shift->req->url;
    my $query = $url->query->to_string;
    my $r = $url->path->to_string . (length $query ? "?$query" : '');
    return $r;
}

1;
