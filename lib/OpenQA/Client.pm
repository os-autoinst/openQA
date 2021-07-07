# Copyright (C) 2014-2020 SUSE LLC
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

package OpenQA::Client;
use Mojo::Base 'OpenQA::UserAgent';
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
