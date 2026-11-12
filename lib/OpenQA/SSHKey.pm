# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::SSHKey;
use Mojo::Base -strict, -signatures;

use Exporter 'import';
use Digest::SHA qw(sha256_hex);
use File::Temp qw(tempdir);
use IPC::Run ();
use Mojo::File 'path';
use MIME::Base64 qw(decode_base64 encode_base64);

our @EXPORT_OK = qw(parse_public_key signature_payload sign_payload verify_signature);

use constant NAMESPACE => 'openqa';

sub parse_public_key ($text) {
    my @lines = grep { /\S/ } split /\n/, $text // '';
    return undef unless @lines == 1;
    my ($type, $blob) = $lines[0] =~ /^\s*(ssh-\S+|ecdsa-\S+|sk-\S+)\s+(\S+)/ or return undef;
    my $public_key = "$type $blob";
    my $fingerprint = _fingerprint($public_key) or return undef;
    return {public_key => $public_key, fingerprint => $fingerprint};
}

sub signature_payload ($method, $request_path, $timestamp, $body) {
    join "\n", $method, $request_path, $timestamp, sha256_hex($body // '');
}

sub sign_payload ($private_key_file, $payload) {
    my $out = _run([qw(ssh-keygen -Y sign -n), NAMESPACE, '-f', $private_key_file], $payload);
    return encode_base64($out->{stdout}, '') if $out->{ok};
    chomp(my $reason = $out->{stderr} // 'unknown error');
    die qq{Signing with SSH key "$private_key_file" failed: $reason\n};
}

sub verify_signature ($public_key, $payload, $encoded_signature) {
    my $dir = tempdir(CLEANUP => 1);
    my $signers = path($dir, 'allowed_signers');
    my $sig = path($dir, 'signature');
    $signers->spurt("openqa $public_key\n");
    $sig->spurt(decode_base64($encoded_signature // ''));
    my $out = _run([qw(ssh-keygen -Y verify -n), NAMESPACE, '-f', "$signers", '-I', 'openqa', '-s', "$sig"], $payload,);
    return $out->{ok};
}

sub _fingerprint ($public_key) {
    my $out = _run([qw(ssh-keygen -lf -)], $public_key);
    return undef unless $out->{ok};
    my ($fingerprint) = $out->{stdout} =~ /^\d+\s+(SHA256:\S+)/;
    return $fingerprint;
}

sub _run ($cmd, $input) {
    my ($stdout, $stderr);
    my $ok = IPC::Run::run($cmd, \$input, \$stdout, \$stderr);
    return {ok => $ok, stdout => $stdout, stderr => $stderr};
}

1;
