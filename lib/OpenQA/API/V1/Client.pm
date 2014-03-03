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

use Mojo::UserAgent;
use Mojo::Util 'hmac_sha1_sum';

sub new {
    my $class = shift;
    my ($key, $secret)= @_;

    my $self = bless {key => $key, secret => $secret}, $class;
    return $self;
}

sub call {
    my $self = shift;
    my ($method, $url, $form) = (shift, shift, shift);
    my $obj = shift;

    unless ($obj) {
        $obj = ($method =~ /_ok$/) ?  Test::Mojo->new('OpenQA') : Mojo::UserAgent->new;
    }

    my $headers = { Accept => 'application/json' };
    $headers->{'X-API-Key'} = $self->{key};
    my $timestamp = time;
    $headers->{'X-API-Microtime'} = $timestamp;
    $headers->{'X-API-Hash'} = hmac_sha1_sum($self->_path_query($url).$timestamp, $self->{secret});

    $obj->$method($url, $headers => form => $form);
}

sub _path_query {
    my $self  = shift;
    my $url = shift;
    my $query = $url->query->to_string;
    return $url->path->to_string . (length $query ? "?$query" : '');
}

1;
