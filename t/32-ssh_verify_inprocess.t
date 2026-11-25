#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use File::Temp 'tempdir';
use Mojo::File 'path';
use MIME::Base64 qw(decode_base64 encode_base64);
use OpenQA::Test::Utils 'generate_ssh_key';
use OpenQA::SSHKey qw(parse_public_key signature_payload sign_payload verify_signature);
use OpenQA::Test::TimeLimit '10';
use Test::Warnings ':report_warnings';

my $dir = tempdir(CLEANUP => 1);
my %keys = map {
    my $file = "$dir/id_$_";
    ($_ => {private => $file, parsed => parse_public_key(generate_ssh_key($file, $_))});
} qw(ed25519 rsa);

my $payload = signature_payload('GET', '/api/v1/jobs?limit=2', 1_700_000_000, '{"a":1}');

subtest 'signature made by ssh-keygen verifies in process' => sub {
    for my $type (sort keys %keys) {
        my $sig = sign_payload($keys{$type}{private}, $payload);
        ok verify_signature($keys{$type}{parsed}{public_key}, $payload, $sig), "$type signature verifies";
    }
};

subtest 'signature over a different payload is rejected' => sub {
    my $sig = sign_payload($keys{ed25519}{private}, $payload);
    my $other = signature_payload('POST', '/api/v1/jobs?limit=2', 1_700_000_000, '{"a":1}');
    ok !verify_signature($keys{ed25519}{parsed}{public_key}, $other, $sig), 'method change is rejected';
};

subtest 'signature by another key is rejected' => sub {
    my $sig = sign_payload($keys{rsa}{private}, $payload);
    ok !verify_signature($keys{ed25519}{parsed}{public_key}, $payload, $sig), 'key mismatch is rejected';
};

subtest 'signature with an unsupported SSHSIG version is rejected' => sub {
    my $armored = decode_base64(sign_payload($keys{ed25519}{private}, $payload));
    (my $body = $armored) =~ s/.*-----BEGIN SSH SIGNATURE-----\s*(.*?)\s*-----END SSH SIGNATURE-----.*/$1/s;
    my $binary = decode_base64(join '', split /\s+/, $body);
    substr $binary, 9, 1, "\x02";
    my $tampered = "-----BEGIN SSH SIGNATURE-----\n" . encode_base64($binary) . "-----END SSH SIGNATURE-----\n";
    ok !verify_signature($keys{ed25519}{parsed}{public_key}, $payload, encode_base64($tampered, '')),
      'signature with version 2 is rejected';
};

subtest 'corrupted signature blob is rejected without dying' => sub {
    my $sig = sign_payload($keys{ed25519}{private}, $payload);
    my $bad = substr($sig, 0, -8) . 'AAAAAAAA';
    ok !verify_signature($keys{ed25519}{parsed}{public_key}, $payload, $bad), 'tampered signature fails';
    ok !verify_signature($keys{ed25519}{parsed}{public_key}, $payload, 'bm90IGEgc2ln'), 'non-SSHSIG input fails';
};

done_testing();
