# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Auth::Local;
use Mojo::Base -signatures;

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
