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
use Test::Output 'combined_like';

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

subtest 'bcrypt password hashing' => sub {
    for my $case (@test_passwords) {
        my $hash1 = hash_password($case->{pw});
        my $hash2 = hash_password($case->{pw});

        like $hash1, qr/^\$2b\$12\$/, "hash uses the bcrypt 2b subtype with cost 12 for $case->{desc}";
        isnt $hash1, $hash2, "distinct random salts produce distinct hashes for $case->{desc}";
        ok verify_password($case->{pw}, $hash1), "verify_password succeeds for correct password in $case->{desc}";
        ok !verify_password($case->{wrong}, $hash1), "verify_password fails for wrong password in $case->{desc}";
    }

    ok !verify_password('secret', '$2b$invalid_format'), 'verify_password safely rejects malformed bcrypt hash';
};

subtest 'persisted hashes of both formats verify' => sub {
    ok verify_password('persisted_bcrypt_pw', '$2b$12$xrFUOKg1dIivPybTsipYBORjPSXwce3Fz1A6NCx67MAvR3OgchLDi'),
      'persisted bcrypt hash verifies';
    ok !verify_password('wrong_pw', '$2b$12$xrFUOKg1dIivPybTsipYBORjPSXwce3Fz1A6NCx67MAvR3OgchLDi'),
      'persisted bcrypt hash rejects an incorrect password';
    ok verify_password(
        'persisted_sha512_pw',
        '$6$zJL23IoG0BKjsZRv$dEQ.F3unJPjqzFAsARM7Fe2rm6M9oGSgKtJbNlM0ZjQnpc2VjVvb472HbQY415t5rvAT3LC714ALkoPbvaXwF1'
      ),
      'persisted SHA-512 crypt hash verifies';
    ok !verify_password(
        'wrong_pw',
        '$6$zJL23IoG0BKjsZRv$dEQ.F3unJPjqzFAsARM7Fe2rm6M9oGSgKtJbNlM0ZjQnpc2VjVvb472HbQY415t5rvAT3LC714ALkoPbvaXwF1'
      ),
      'persisted SHA-512 crypt hash rejects an incorrect password';

    my $static_hash = OpenQA::WebAPI::Auth::Local::hash_password('package_static_pass');
    ok OpenQA::WebAPI::Auth::Local::verify_password('package_static_pass', $static_hash),
      'package-statically invoked hash and verify functions round-trip correctly';
    ok !OpenQA::WebAPI::Auth::Local::verify_password('wrong_pass', $static_hash),
      'package-statically invoked verify function rejects wrong password';
};

subtest 'SHA-512 fallback when crypt() supports no bcrypt' => sub {
    my $mock_local = Test::MockModule->new('OpenQA::WebAPI::Auth::Local');
    $mock_local->redefine(_crypt => sub ($pw, $setting) { $setting =~ /^\$2b\$/ ? '*0' : crypt $pw, $setting });

    for my $case (@test_passwords) {
        my ($hash1, $hash2);
        combined_like { $hash1 = hash_password($case->{pw}); $hash2 = hash_password($case->{pw}) }
        qr/SHA-512 instead/, "bcrypt-less crypt() is reported for $case->{desc}";

        like $hash1, qr/^\$6\$/, "fallback hash uses the SHA-512 crypt prefix for $case->{desc}";
        isnt $hash1, $hash2, "distinct random salts produce distinct fallback hashes for $case->{desc}";
        ok verify_password($case->{pw}, $hash1),
          "fallback verify_password succeeds for correct password in $case->{desc}";
        ok !verify_password($case->{wrong}, $hash1),
          "fallback verify_password fails for wrong password in $case->{desc}";
    }
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
