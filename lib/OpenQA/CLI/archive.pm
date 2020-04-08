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

package OpenQA::CLI::archive;
use Mojo::Base 'OpenQA::Command';

use Mojo::Util qw(getopt);

has description => 'Download assets and test results from a job';
has usage       => sub { shift->extract_usage };

sub run {
    my ($self, @args) = @_;

    getopt \@args,
      'apibase=s'            => \(my $base = '/api/v1'),
      'apikey=s'             => \my $key,
      'apisecret=s'          => \my $secret,
      'H|host=s'             => \(my $host = 'http://localhost'),
      'l|asset-size-limit=i' => \(my $limit),
      't|with-thumbnails'    => \my $thumbnails;

    @args = $self->decode_args(@args);
    die $self->usage unless my $job  = shift @args;
    die $self->usage unless my $path = shift @args;

    my $url = Mojo::URL->new($host);
    $url->path($self->prepend_apibase($base, "jobs/$job/details"));

    my $client = $self->client(apikey => $key, apisecret => $secret, api => $url->host);
    $client->archive->run(
        {url => $url, archive => $path, 'with-thumbnails' => $thumbnails, 'asset-size-limit' => $limit});
}

1;

=encoding utf8

=head1 SYNOPSIS

  Usage: openqa-cli archive [OPTIONS] JOB PATH

    openqa-cli archive --host http://openqa-staging-1.qa.suse.de 407 /tmp/foo
    openqa-cli archive -l 1048576000 -t 408 /tmp/bar

  Options:
        --apibase <path>           API base, defaults to /api/v1
        --apikey <key>             API key
        --apisecret <secret>       API secret
    -H, --host <host>              Target host, defaults to http://localhost
    -h, --help                     Show this summary of available options
    -l, --asset-size-limit <num>   Asset size limit in bytes
    -t, --with-thumbnails          Download thumbnails as well

=cut
