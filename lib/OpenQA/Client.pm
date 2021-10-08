# Copyright 2014-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Client;
use Mojo::Base 'OpenQA::UserAgent', -base, -signatures;
use OpenQA::Client::Upload;
use OpenQA::Client::Archive;


has upload => sub {
    my $upload = OpenQA::Client::Upload->new(client => shift);
    Scalar::Util::weaken $upload->{client};
    return $upload;
};

has archive => sub {
    my $archive = OpenQA::Client::Archive->new(client => shift);
    Scalar::Util::weaken $archive->{client};
    return $archive;
};

sub url_from_host ($host) {
    return Mojo::URL->new($host) if $host =~ '/';
    my $url = Mojo::URL->new();
    $url->host($host);
    $url->scheme($host =~ qr/localhost/ ? 'http' : 'https');
    return $url;
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
tries to find a config file in $OPENQA_CONFIG,
~/.config/openqa/client.conf or /etc/openqa/client.conf and reads
whatever comes first.

See L<Mojo::UserAgent> for more.

=head1 ATTRIBUTES

L<OpenQA::Client> inherits from L<OpenQA::UserAgent> and implements the following attributes.

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
