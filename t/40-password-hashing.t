#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Mojo::Base -signatures;
use Test::Most;
use Test::MockModule;
use Test::Warnings ':report_warnings';

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '10';
use OpenQA::WebAPI::Auth::Local qw(hash_password verify_password);
use Mojo::Util 'secure_compare';

my $mock_bcrypt;

BEGIN {
    unless (eval { require Crypt::Bcrypt; 1 }) {

        package Crypt::Bcrypt;
        $INC{'Crypt/Bcrypt.pm'} = 'mocked';
        sub bcrypt { }
        sub bcrypt_check { }
    }
}

BEGIN {
    unless (eval { require Crypt::Argon2; 1 }) {

        package Crypt::Argon2;
        $INC{'Crypt/Argon2.pm'} = 'mocked';
        sub argon2id_pass { }
        sub argon2_verify { }
    }
}

$mock_bcrypt = Test::MockModule->new('Crypt::Bcrypt');
$mock_bcrypt->redefine(
    bcrypt => sub ($pw, $subtype, $cost, $salt) {
        my $salt_hex = unpack 'H*', $salt;
        return '$2b$' . $cost . '$' . $salt_hex . $pw;
    });
$mock_bcrypt->redefine(
    bcrypt_check => sub ($pw, $hash) {
        die 'malformed bcrypt hash' unless $hash =~ /^\$2b\$12\$([0-9a-f]{32})(.*)$/;
        return secure_compare($2, $pw);
    });

my $mock_argon2 = Test::MockModule->new('Crypt::Argon2');
$mock_argon2->redefine(
    argon2id_pass => sub ($pw, $salt, $t_cost, $m_factor, $parallelism, $tag_size) {
        return '$argon2id$v=19$m=16384,t=3,p=1$' . unpack('H*', $salt) . '$' . $pw;
    });
$mock_argon2->redefine(
    argon2_verify => sub ($hash, $pw) {
        return 0 unless $hash =~ /^\$argon2id\$[^\$]*\$[^\$]*\$([0-9a-f]{32})\$(.*)$/;
        return secure_compare($2, $pw);
    });

my @test_passwords = (
    {desc => 'simple alphanumeric password', pw => 'secret123', wrong => 'secret124'},
    {desc => 'password with special characters', pw => 'P@$$w0rd!#%^&*()', wrong => 'P@$$w0rd!#%^&*(_'},
    {
        desc => 'long passphrase',
        pw => 'correct horse battery staple with many words',
        wrong => 'correct horse battery staple with many wordz'
    },
    {desc => 'unicode characters in password', pw => 'p@ssw0rd✓üñîçødé', wrong => 'p@ssw0rd✓üñîçøde'},
);

subtest 'bcrypt password hashing path' => sub {
    my $mock_local = Test::MockModule->new('OpenQA::WebAPI::Auth::Local');
    $mock_local->redefine(_has_argon2 => sub { 0 });
    for my $case (@test_passwords) {
        my $hash1 = hash_password($case->{pw});
        my $hash2 = hash_password($case->{pw});

        like $hash1, qr/^\$2b\$12\$/, "bcrypt hash uses 2b subtype with cost 12 for $case->{desc}";
        isnt $hash1, $hash2, "distinct random salts produce distinct bcrypt hashes for $case->{desc}";
        ok verify_password($case->{pw}, $hash1), "verify_password succeeds for correct password in $case->{desc}";
        ok !verify_password($case->{wrong}, $hash1), "verify_password fails for wrong password in $case->{desc}";
    }

    ok !verify_password('secret', '$2b$invalid_format'), 'verify_password safely rejects malformed bcrypt hash';
};

subtest 'Argon2id preferred over bcrypt when both strong KDFs available' => sub {
    my $mock_local = Test::MockModule->new('OpenQA::WebAPI::Auth::Local');
    $mock_local->redefine(_has_argon2 => sub { 1 });

    for my $case (@test_passwords) {
        my $hash = hash_password($case->{pw});
        like $hash, qr/^\$argon2id\$/, "hash_password selects Argon2id over bcrypt for $case->{desc}";
        isnt hash_password($case->{pw}), $hash,
          "distinct random salts produce distinct Argon2id hashes for $case->{desc}";
        ok verify_password($case->{pw}, $hash),
          "Argon2id verify_password succeeds for correct password in $case->{desc}";
        ok !verify_password($case->{wrong}, $hash),
          "Argon2id verify_password fails for wrong password in $case->{desc}";
    }

    ok !verify_password('secret', '$argon2id$malformed'), 'verify_password safely rejects malformed Argon2id hash';
};

subtest 'strong KDF runtime detection is optional and non-fatal' => sub {
    ok OpenQA::WebAPI::Auth::Local::_has_argon2(),
      'has_argon2 returns true when Crypt::Argon2 is loadable (stubbed in this test file)';
    ok OpenQA::WebAPI::Auth::Local::_has_bcrypt(),
      'has_bcrypt returns true when Crypt::Bcrypt is loadable (stubbed in this test file)';
};

subtest 'legacy weak crypt fallback only when explicitly requested' => sub {
    my $mock_local = Test::MockModule->new('OpenQA::WebAPI::Auth::Local');
    $mock_local->redefine(_has_argon2 => sub { 0 });
    $mock_local->redefine(_has_bcrypt => sub { 0 });

    for my $case (@test_passwords) {
        my $hash1 = hash_password($case->{pw}, {allow_weak_fallback => 1});
        my $hash2 = hash_password($case->{pw}, {allow_weak_fallback => 1});

        like $hash1, qr/^\$6\$/, "fallback hash uses SHA-512 crypt prefix for $case->{desc}";
        isnt $hash1, $hash2, "distinct random salts produce distinct crypt hashes for $case->{desc}";
        ok verify_password($case->{pw}, $hash1),
          "fallback verify_password succeeds for correct password in $case->{desc}";
        ok !verify_password($case->{wrong}, $hash1),
          "fallback verify_password fails for wrong password in $case->{desc}";
    }
};

subtest 'production guard fails closed when no strong KDF available' => sub {
    my $mock_local = Test::MockModule->new('OpenQA::WebAPI::Auth::Local');
    $mock_local->redefine(_has_argon2 => sub { 0 });
    $mock_local->redefine(_has_bcrypt => sub { 0 });

    throws_ok { hash_password('somepass') } qr/No strong password hashing/,
      'hash_password croaks instead of weak crypt fallback when neither Argon2id nor bcrypt is available';

    my @weak_cases = (
        {desc => 'weak fallback requested explicitly', pw => 'somepass', opts => {allow_weak_fallback => 1}},
        {desc => 'weak fallback not requested', pw => 'other', opts => {}},
    );
    for my $case (@weak_cases) {
        if ($case->{opts}->{allow_weak_fallback}) {
            my $weak = hash_password($case->{pw}, $case->{opts});
            like $weak, qr/^\$6\$/, "explicit weak fallback flag yields SHA-512 crypt hash for $case->{desc}";
            ok verify_password($case->{pw}, $weak), "weak crypt fallback verifies correct password for $case->{desc}";
            ok !verify_password('wrong', $weak), "weak crypt fallback rejects wrong password for $case->{desc}";
        }
        else {
            throws_ok { hash_password($case->{pw}, $case->{opts}) } qr/No strong password hashing/,
              "empty options still fail closed for $case->{desc}";
        }
    }
};

subtest 'cross-compatibility and static package invocation' => sub {
    my $mock_local = Test::MockModule->new('OpenQA::WebAPI::Auth::Local');
    $mock_local->redefine(_has_argon2 => sub { 0 });
    $mock_local->redefine(_has_bcrypt => sub { 0 });
    my $sha512_hash = hash_password('persisted_sha512_pw', {allow_weak_fallback => 1});
    $mock_local->unmock('_has_bcrypt');

    ok verify_password('persisted_sha512_pw', $sha512_hash),
      'SHA-512 fallback hash is correctly verified even when bcrypt is enabled';
    ok !verify_password('wrong_pw', $sha512_hash),
      'SHA-512 fallback hash rejects incorrect password when bcrypt is enabled';

    my $static_hash = OpenQA::WebAPI::Auth::Local::hash_password('package_static_pass');
    ok OpenQA::WebAPI::Auth::Local::verify_password('package_static_pass', $static_hash),
      'package-statically invoked hash and verify functions round-trip correctly';
    ok !OpenQA::WebAPI::Auth::Local::verify_password('wrong_pass', $static_hash),
      'package-statically invoked verify function rejects wrong password';
};

subtest 'input validation and error handling' => sub {
    my @invalid_hash_inputs
      = ({desc => 'undefined password', input => undef}, {desc => 'empty password string', input => ''},);
    for my $case (@invalid_hash_inputs) {
        throws_ok { hash_password($case->{input}) } qr/Password is required/, "hash_password croaks on $case->{desc}";
    }

    my @invalid_verify_inputs = (
        {desc => 'undefined password with valid hash', pw => undef, hash => '$6$salt$validhash'},
        {desc => 'valid password with undefined hash', pw => 'secret', hash => undef},
        {desc => 'valid password with empty hash', pw => 'secret', hash => ''},
        {desc => 'valid password with non-hash garbage', pw => 'secret', hash => 'not_a_hash'},
    );
    for my $case (@invalid_verify_inputs) {
        ok !verify_password($case->{pw}, $case->{hash}), "verify_password returns 0 for $case->{desc}";
    }
};

done_testing;
