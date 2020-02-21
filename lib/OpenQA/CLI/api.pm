# Copyright (C) 2020 SUSE Linux Products GmbH
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

package OpenQA::CLI::api;
use Mojo::Base 'OpenQA::Command';

use Mojo::URL;
use Mojo::Util qw(decode getopt);

has description => 'Issue an arbitrary request to the API';
has usage       => sub { shift->extract_usage };

sub run {
    my ($self, @args) = @_;

    my $data = $self->data_from_stdin;

    getopt \@args,
      'a|header=s'  => \my @headers,
      'apibase=s'   => \(my $base = '/api/v1'),
      'apikey=s'    => \my $key,
      'apisecret=s' => \my $secret,
      'd|data=s'    => \$data,
      'H|host=s'    => \(my $host = 'http://localhost'),
      'X|method=s'  => \(my $method = 'GET');

    @args = map { decode 'UTF-8', $_ } @args;
    die $self->usage unless my $path = shift @args;
    $path = "/$path" unless $path =~ m!^/!;
    $path = "$base$path";

    my $url = Mojo::URL->new($host);
    $url->path($path);

    my $client  = $self->client(apikey => $key, apisecret => $secret, api => $url->host);
    my $headers = $self->parse_headers(@headers);
    my $tx      = $client->build_tx($method, $url, $headers, $data);
    $tx = $client->start($tx);
    $self->handle_result($tx);
}

1;

=encoding utf8

=head1 SYNOPSIS

  Usage: openqa-cli api [OPTIONS] PATH

    openqa-cli api -H https://openqa.opensuse.org job_templates_scheduling/24

  Options:
        --apibase <path>        API base, defaults to /api/v1
        --apikey <key>          API key
        --apisecret <secret>    API secret
    -a, --header <name:value>   One or more additional HTTP headers
    -d, --data <string>         Content to send with request, alternatively you
                                can also pipe data to openqa-cli
    -H, --host <host>           Target host, defaults to http://localhost
    -h, --help                  Show this summary of available options
    -X, --method <method>       HTTP method to use, defaults to GET

=cut
