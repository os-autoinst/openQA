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

# Argon2 is optional at runtime so it is not a hard packaging dependency.
sub _has_argon2 () {
    return eval { require Crypt::Argon2; 1 } ? 1 : 0;
}

# Prefer Argon2id, then bcrypt. The weak crypt() fallback is opt-in only, so the
# production path fails closed instead of silently downgrading when no strong KDF is present.
sub hash_password ($pw, $opts = {}) {
    croak 'Password is required' unless defined $pw && length $pw;
    $pw = encode('UTF-8', $pw) if utf8::is_utf8($pw);
    if (_has_argon2()) {
        my $salt = random_bytes(16);
        return Crypt::Argon2::argon2id_pass($pw, $salt, 3, '16M', 1, 16);
    }
    if (_has_bcrypt()) {
        my $salt = random_bytes(16);
        return Crypt::Bcrypt::bcrypt($pw, '2b', 12, $salt);
    }
    croak 'No strong password hashing available (need Argon2id or bcrypt)'
      unless $opts->{allow_weak_fallback};
    my $salt = random_string(16);
    return crypt $pw, '$6$' . $salt . '$';
}

sub verify_password ($pw, $hash) {
    return 0 unless defined $pw && defined $hash && length $hash;
    $pw = encode('UTF-8', $pw) if utf8::is_utf8($pw);
    if ($hash =~ /^\$argon2/) {
        return _has_argon2() && eval { Crypt::Argon2::argon2_verify($hash, $pw) } ? 1 : 0;
    }
    if ($hash =~ /^\$2[abxy]?\$/) {
        return _has_bcrypt() && eval { Crypt::Bcrypt::bcrypt_check($pw, $hash) } ? 1 : 0;
    }
    my $computed = eval { crypt $pw, $hash } // '';
    return secure_compare($computed, $hash) ? 1 : 0;
}

sub auth_setup ($server) {
    return;
}

sub auth_logout ($c) {
    delete $c->session->{user};
    return;
}

sub auth_login ($c) {
    if ($c->req->method eq 'GET') {
        $c->render('main/login');
        return (manual => 1);
    }

    my $username = $c->param('username');
    my $password = $c->param('password');

    if (defined $username && defined $password && length $username && length $password) {
        my $user = $c->schema->resultset('Users')->find({username => $username, provider => 'Local'});
        if ($user && !$user->is_deleted && $user->password && verify_password($password, $user->password)) {
            $c->session->{user} = $user->username;
            return (error => 0);
        }
    }

    return (error => 'Invalid username or password');
}

1;
