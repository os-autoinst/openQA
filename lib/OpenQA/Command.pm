# Copyright (C) 2020 SUSE LLC
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

package OpenQA::Command;
use Mojo::Base 'Mojolicious::Command';

use OpenQA::Client;
use Mojo::IOLoop;

sub client {
    my $self = shift;
    return OpenQA::Client->new(@_)->ioloop(Mojo::IOLoop->singleton);
}

sub data_from_stdin {
    vec(my $r = '', fileno(STDIN), 1) = 1;
    return !-t STDIN && select($r, undef, undef, 0) ? join '', <STDIN> : '';
}

sub handle_result {
    my ($self, $tx) = @_;
    say $tx->res->body;
}

sub parse_headers {
    my ($self, @headers) = @_;
    return {map { /^\s*([^:]+)\s*:\s*(.*+)$/ ? ($1, $2) : () } @headers};
}

sub parse_params {
    my ($self, @args) = @_;
    return {map { /^([[:alnum:]_\[\]\.]+)=(.+)$/s ? ($1, $2) : () } @args};
}

sub prepend_apibase {
    my ($self, $base, $path) = @_;
    $path = "/$path" unless $path =~ m!^/!;
    return "$base$path";
}

1;
