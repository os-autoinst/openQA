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

package OpenQA::Client;

use Mojo::Base 'Mojo::UserAgent';
use Mojo::Util 'hmac_sha1_sum';
use Config::IniFiles;
use Scalar::Util ();

use Carp;

has 'apikey';
has 'apisecret';

sub new {
    my $self = shift->SUPER::new;
    my %args = @_;

    for my $i (qw/apikey apisecret/) {
        next unless $args{$i};
        $self->$i($args{$i});
    }

    if ($args{api}) {
        my @cfgpaths=(glob('~/.config/openqa'), '/etc/openqa');
        @cfgpaths=($ENV{OPENQA_CONFIG},@cfgpaths) if defined $ENV{OPENQA_CONFIG};
        for my $path (@cfgpaths) {
            my $file=$path.'/client.conf';
            next unless $file && -r $file;
            my $cfg = Config::IniFiles->new(-file => $file) || last;
            last unless $cfg->SectionExists($args{api});
            for my $i (qw/key secret/) {
                my $attr = "api$i";
                next if $self->$attr;
                (my $val = $cfg->val($args{api}, $i)) =~ s/\s+$//; # remove trailing whitespace
                $self->$attr($val);
            }
            last;
        }
    }
    # When database locking arises, the server takes some time to reply.
    # We could also adjust sqlite_busy_timeout in DBI server side.
    $self->inactivity_timeout(40);

    $self->on(
        start => sub {
            $self->_add_auth_headers(@_);
        }
    );

    return $self;
}

sub _add_auth_headers {
    my ($self, $ua, $tx) = @_;

    unless ($self->apisecret && $self->apikey) {
        carp "missing apisecret and/or apikey" unless $tx->req->method eq 'GET';
        return;
    }

    my $timestamp = time;
    my %headers = (
        Accept => 'application/json',
        'X-API-Key' => $self->apikey,
        'X-API-Microtime' => $timestamp,
        'X-API-Hash' => hmac_sha1_sum($self->_path_query($tx).$timestamp, $self->apisecret),
    );

    while (my ($k, $v) = each %headers) {
        $tx->req->headers->header($k, $v);
    }
}

sub _path_query {
    my $self  = shift;
    my $url = shift->req->url;
    my $query = $url->query->to_string;
    # as use this for hashing, we need to make sure the query is escaping
    # space the same as the mojo url parser.
    $query =~ s,%20,+,g;
    my $r = $url->path->to_string . (length $query ? "?$query" : '');
    return $r;
}

1;

=encoding utf8

=head1 NAME

OpenQA::Client - special version of Mojo::UserAgent that handles authentication

=head1 SYNOPSIS

  use OpenQA::Client;

  # create new UserAgent that is meant to talk to localhost. Reads key
  # and secret from config section [localhost]
  my $ua = OpenQA::Client->new(api => 'localhost');

  # specify key and secret manually
  my $ua = OpenQA::Client->new(apikey => 'foo', apisecret => 'bar');

=head1 DESCRIPTION

L<OpenQA::Client> inherits from L<Mojo::UserAgent>. It
automatically sets the correct authentication headers if API key and
secret are available.

API key and secret can either be set manually in the constructor, via
attributes or read from a config file. L<OpenQA::Client>
tries to find a config file in $OPENQA_CLIENT_CONFIG,
~/.config/openqa/client.conf or /etc/openqa/client.conf and reads
whatever comes first.

See L<Mojo::UserAgent> for more.

=head1 ATTRIBUTES

L<OpenQA::Client> implmements the following attributes.

=head2 apikey

  my $apikey = $ua->apikey;
  $ua        = $ua->apikey('foo');

The API public key

=head2 apisecret

  my $apisecret = $ua->apisecret;
  $ua           = $ua->apisecret('bar');

The API secret key

=head1 METHODS

=head2 new

  my $ua = OpenQA::Client->new(api => 'localhost');
  my $ua = OpenQA::Client->new(apikey => 'foo', apisecret => 'bar');

Generate the L<OpenQA::Client> object.

=head1 CONFIG FILE FORMAT

The config file is in ini format. The sections are the host name of
the api.

  [openqa.example.com]
  key = foo
  secret = bar

=head1 SEE ALSO

L<Mojo::UserAgent>, L<Config::IniFiles>

=cut
# vim: set sw=4 et:
