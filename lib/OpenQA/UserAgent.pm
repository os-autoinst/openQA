# Copyright 2018-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::UserAgent;
use Mojo::Base 'Mojo::UserAgent', -signatures;

use OpenQA::Config;
use Mojo::File 'path';
use Mojo::Util 'hmac_sha1_sum';
use Scalar::Util ();
use Carp;

has [qw(apikey apisecret base_url)];

sub new {
    my $self = shift->SUPER::new(@_);
    my %args = @_;
    for my $i (qw(apikey apisecret)) {
        $self->$i($args{$i}) if $args{$i};
    }

    $self->configure_credentials($args{api});

    # Scheduling a couple of hundred jobs takes quite some time - so we better wait a couple of minutes
    # (default is 20 seconds)
    $self->inactivity_timeout(600);

    # Some urls might redirect to https and then there are internal redirects for assets
    $self->max_redirects(3);

    $self->on(start => sub ($ua, $tx) { $self->_add_headers($tx) });

    #read proxy environment variables
    $self->proxy->detect;

    return $self;
}

sub open_config_file ($host) {
    return undef unless $host;
    my $cfg = parse_config_files(lookup_config_files(path(glob('~/.config/openqa')), 'client.conf', 1));
    return $cfg && $cfg->SectionExists($host) ? $cfg : undef;
}

sub configure_credentials ($self, $host) {
    return undef unless my $cfg = open_config_file($host);
    for my $i (qw(key secret)) {
        my $attr = "api$i";
        next if $self->$attr;
        # Fetch all the values in the file and keep the last one
        my @values = $cfg->val($host, $i);
        next unless my $val = $values[-1];
        $val =~ s/\s+$//;    # remove trailing whitespace
        $self->$attr($val);
    }
}

sub add_auth_headers ($headers, $url, $apikey, $apisecret) {
    my $timestamp = time;
    $headers->header('X-API-Microtime', $timestamp);
    if ($apikey && $apisecret) {
        $headers->header('X-API-Key', $apikey);
        $headers->header('X-API-Hash', hmac_sha1_sum(_path_query($url) . $timestamp, $apisecret));
    }
}

sub _add_headers ($self, $tx) {
    my $req = $tx->req;
    my $headers = $req->headers;
    $headers->accept('application/json') unless defined $headers->accept;
    add_auth_headers($headers, $req->url, $self->apikey, $self->apisecret);
}

sub _path_query ($url) {
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
