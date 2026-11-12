#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use File::Temp 'tempdir';
use Mojo::File 'path';
use OpenQA::Test::Utils 'generate_ssh_key';
use OpenQA::SSHKey qw(parse_public_key signature_payload sign_payload verify_signature);
use Test::Warnings ':report_warnings';

my $dir = tempdir(CLEANUP => 1);
my %keys = map {
    my $file = "$dir/id_$_";
    ($_ => {private => $file, public => generate_ssh_key($file, $_)});
} qw(ed25519 rsa);

subtest 'parse_public_key' => sub {
    for my $type (sort keys %keys) {
        my $parsed = parse_public_key($keys{$type}{public});
        like $parsed->{fingerprint}, qr/^SHA256:\S+$/, "$type public key yields a SHA256 fingerprint";
        like qx{ssh-keygen -lf $keys{$type}{private}}, qr/\Q$parsed->{fingerprint}\E/,
          "$type fingerprint matches ssh-keygen output";
        like $parsed->{public_key}, qr/^ssh-(ed25519|rsa) /, "$type normalized public key keeps the key type";
    }
    is parse_public_key("  \n"), undef, 'blank input is not a public key';
    is parse_public_key('not a key'), undef, 'arbitrary text is not a public key';
    is parse_public_key(path($keys{ed25519}{private})->slurp), undef, 'private key material is rejected';
    is parse_public_key($keys{ed25519}{public} . $keys{rsa}{public}), undef, 'more than one key is rejected';
};

subtest 'signature_payload' => sub {
    is signature_payload('POST', '/api/v1/jobs', 1_700_000_000, ''),
      "POST\n/api/v1/jobs\n1700000000\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      'payload is method, path, timestamp and sha256 of the empty body';
    isnt signature_payload('POST', '/a', 1, 'x'), signature_payload('POST', '/a', 1, 'y'),
      'payload depends on the body';
};

for my $type (sort keys %keys) {
    subtest "sign and verify with $type key" => sub {
        my $payload = signature_payload('POST', '/api/v1/jobs', 1_700_000_000, 'body');
        my $encoded = sign_payload($keys{$type}{private}, $payload);
        unlike $encoded, qr/\s/, 'encoded signature is a single header-safe token';
        my $public = parse_public_key($keys{$type}{public})->{public_key};
        ok verify_signature($public, $payload, $encoded), 'signature verifies against the public key';
        ok !verify_signature($public, "$payload-tampered", $encoded), 'signature fails for a different payload';
        my $other = parse_public_key($keys{$type eq 'rsa' ? 'ed25519' : 'rsa'}{public})->{public_key};
        ok !verify_signature($other, $payload, $encoded), 'signature fails for a different key';
    };
}

done_testing();
