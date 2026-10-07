# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Auth::Local;
use Mojo::Base -base, -signatures;

use Carp 'croak';
use Crypt::PRNG qw(random_string);
use Exporter 'import';
use Mojo::Util qw(encode secure_compare);
use OpenQA::Log 'log_warning';

our @EXPORT_OK = qw(hash_password verify_password);

sub hash_password ($pw) {
    croak 'Password is required' unless defined $pw && length $pw;
    $pw = encode('UTF-8', $pw) if utf8::is_utf8($pw);
    my $hash = _crypt($pw, '$2b$12$' . random_string(22));
    return $hash if $hash =~ /^\$2b\$12\$/;
    log_warning 'crypt() supports no bcrypt hashes, hashing the password with SHA-512 instead';
    return _crypt($pw, '$6$' . random_string(16));
}

sub verify_password ($pw, $hash) {
    return 0 unless defined $pw && defined $hash && length $hash;
    $pw = encode('UTF-8', $pw) if utf8::is_utf8($pw);
    return secure_compare(_crypt($pw, $hash) // '', $hash);
}

sub _crypt ($pw, $setting) { return crypt $pw, $setting }

1;
