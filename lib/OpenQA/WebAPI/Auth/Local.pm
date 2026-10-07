# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Auth::Local;
use Mojo::Base -base, -signatures;

use Carp 'croak';
use Crypt::PRNG qw(random_bytes random_string);
use Exporter 'import';
use Mojo::Util qw(encode secure_compare);

our @EXPORT_OK = qw(hash_password verify_password);

sub _has_bcrypt () {
    return eval { require Crypt::Bcrypt; 1 } ? 1 : 0;
}

sub hash_password ($pw) {
    croak 'Password is required' unless defined $pw && length $pw;
    $pw = encode('UTF-8', $pw) if utf8::is_utf8($pw);
    if (_has_bcrypt()) {
        my $salt = random_bytes(16);
        return Crypt::Bcrypt::bcrypt($pw, '2b', 12, $salt);
    }
    my $salt = random_string(16);
    return crypt $pw, '$6$' . $salt . '$';
}

sub verify_password ($pw, $hash) {
    return 0 unless defined $pw && defined $hash && length $hash;
    $pw = encode('UTF-8', $pw) if utf8::is_utf8($pw);
    if ($hash =~ /^\$2[abxy]?\$/ && _has_bcrypt()) {
        return eval { Crypt::Bcrypt::bcrypt_check($pw, $hash) } ? 1 : 0;
    }
    my $computed = eval { crypt $pw, $hash } // '';
    return secure_compare($computed, $hash) ? 1 : 0;
}

1;
