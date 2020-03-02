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
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::UserAgent;
use Mojo::Base 'Mojo::UserAgent';

use Mojo::Util 'hmac_sha1_sum';
use Config::IniFiles;
use Scalar::Util ();
use Carp;

has [qw(apikey apisecret base_url)];

sub new {
    my $self = shift->SUPER::new(@_);
    my %args = @_;

    for my $i (qw(apikey apisecret)) {
        next unless $args{$i};
        $self->$i($args{$i});
    }

    if ($args{api}) {
        my @cfgpaths = (glob('~/.config/openqa'), '/etc/openqa');
        @cfgpaths = ($ENV{OPENQA_CONFIG}, @cfgpaths) if defined $ENV{OPENQA_CONFIG};
        for my $path (@cfgpaths) {
            my $file = $path . '/client.conf';
            next unless $file && -r $file;
            my $cfg = Config::IniFiles->new(-file => $file) || last;
            last unless $cfg->SectionExists($args{api});
            for my $i (qw(key secret)) {
                my $attr = "api$i";
                next if $self->$attr;
                (my $val = $cfg->val($args{api}, $i)) =~ s/\s+$//;    # remove trailing whitespace
                $self->$attr($val);
            }
            last;
        }
    }
    # Scheduling a couple of hundred jobs takes quite some time - so we better wait a couple of minutes
    # (default is 20 seconds)
    $self->inactivity_timeout(600);

    # Some urls might redirect to https and then there are internal redirects for assets
    $self->max_redirects(3);

    $self->on(
        start => sub {
            $self->_add_auth_headers(@_);
        });

    return $self;
}

sub _add_auth_headers {
    my ($self, $ua, $tx) = @_;

    my $timestamp = time;
    my %headers   = (
        Accept            => 'application/json',
        'X-API-Microtime' => $timestamp
    );
    if ($self->apisecret && $self->apikey) {
        $headers{'X-API-Key'}  = $self->apikey;
        $headers{'X-API-Hash'} = hmac_sha1_sum($self->_path_query($tx) . $timestamp, $self->apisecret);
    }

    while (my ($k, $v) = each %headers) {
        $tx->req->headers->header($k, $v);
    }
}

sub _path_query {
    my $self  = shift;
    my $url   = shift->req->url;
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

OpenQA::UserAgent - special version of Mojo::UserAgent that handles authentication

=head1 SYNOPSIS

  use OpenQA::UserAgent;

  # create new UserAgent that is meant to talk to localhost. Reads key
  # and secret from config section [localhost]
  my $ua = OpenQA::UserAgent->new(api => 'localhost');

  # specify key and secret manually
  my $ua = OpenQA::UserAgent->new(apikey => 'foo', apisecret => 'bar');

=head1 DESCRIPTION

L<OpenQA::UserAgent> inherits from L<Mojo::UserAgent>. It
automatically sets the correct authentication headers if API key and
secret are available.

API key and secret can either be set manually in the constructor, via
attributes or read from a config file. L<OpenQA::UserAgent>
tries to find a config file in $OPENQA_CONFIG,
~/.config/openqa/client.conf or /etc/openqa/client.conf and reads
whatever comes first.

See L<Mojo::UserAgent> for more.

=head1 ATTRIBUTES

L<OpenQA::UserAgent> implmements the following attributes.

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

  my $ua = OpenQA::UserAgent->new(api => 'localhost');
  my $ua = OpenQA::UserAgent->new(apikey => 'foo', apisecret => 'bar');

Generate the L<OpenQA::UserAgent> object.

=head1 CONFIG FILE FORMAT

The config file is in ini format. The sections are the host name of
the api.

  [openqa.example.com]
  key = foo
  secret = bar

=head1 SEE ALSO

L<Mojo::UserAgent>, L<Config::IniFiles>

=cut
