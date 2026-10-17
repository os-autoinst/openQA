# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CLI::token;
use Mojo::Base 'OpenQA::Command', -signatures;
use MIME::Base64 qw(encode_base64url);

has description => 'Encodes authentication tokens from specified credentials';
has usage => sub { OpenQA::CLI->_help('token') };


# Generate a length-optimized, URL escaped, base64 encoded worker token string
# with a prefix abbreviated for "openQA worker token"
sub encode_token ($host, $key, $secret) {
    my ($key_bin, $secret_bin) = map { pack 'H*', $_ } ($key, $secret);
    return 'oqwt-' . encode_base64url join "\x00", $host, $key_bin, $secret_bin;
}

sub command ($self, @args) {
    die $self->usage unless OpenQA::CLI::get_opt(token => \@args, [], \my %options);
    my ($command, $credentials) = $self->decode_args(@args);
    die $self->usage unless $command eq 'encode' || ! length $credentials;
    print encode_token(split /@/, $credentials);
    return 0;
}

1;

