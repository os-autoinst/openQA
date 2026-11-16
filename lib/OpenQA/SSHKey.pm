# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::SSHKey;
use Mojo::Base -strict, -signatures;

use Exporter 'import';
use Crypt::PK::Ed25519;
use Digest::SHA qw(sha256_hex sha512);
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
    my $armored = decode_base64($encoded_signature // '');
    my $verified = _verify_ed25519_in_process($public_key, $payload, $armored);
    return $verified // _verify_with_ssh_keygen($public_key, $payload, $armored);
}

# Returns undef for key types other than ssh-ed25519, which are left to ssh-keygen
sub _verify_ed25519_in_process ($public_key, $payload, $armored) {
    my ($type, $blob) = $public_key =~ /^(\S+)\s+(\S+)/ or return 0;
    return undef unless $type eq 'ssh-ed25519';
    my $sshsig = _parse_sshsig($armored) or return 0;
    my $key_blob = decode_base64($blob);
    return 0 unless $sshsig->{public_key} eq $key_blob && $sshsig->{namespace} eq NAMESPACE;
    return 0 unless $sshsig->{hash_algorithm} eq 'sha512';
    my $raw_key = _ssh_string_fields($key_blob, 2)->[1];
    my $signed = join '', 'SSHSIG', map { pack 'N/a*', $_ } $sshsig->{namespace}, $sshsig->{reserved},
      $sshsig->{hash_algorithm}, sha512($payload);
    return Crypt::PK::Ed25519->new(\_ed25519_spki_pem($raw_key))->verify_message($sshsig->{signature}, $signed) ? 1 : 0;
}

sub _verify_with_ssh_keygen ($public_key, $payload, $armored) {
    my $dir = tempdir(CLEANUP => 1);
    my $signers = path($dir, 'allowed_signers');
    my $sig = path($dir, 'signature');
    $signers->spurt("openqa $public_key\n");
    $sig->spurt($armored);
    my $out = _run([qw(ssh-keygen -Y verify -n), NAMESPACE, '-f', "$signers", '-I', 'openqa', '-s', "$sig"], $payload,);
    return $out->{ok};
}

# Parses the armored SSHSIG format, see PROTOCOL.sshsig in the OpenSSH sources
sub _parse_sshsig ($armored) {
    my ($body) = $armored =~ /-----BEGIN SSH SIGNATURE-----(.*?)-----END SSH SIGNATURE-----/s or return undef;
    my $blob = decode_base64(join '', split /\s+/, $body);
    return undef unless _take($blob, 0, 6) eq 'SSHSIG';
    return undef unless _u32($blob, 6) == 1;
    my $fields = _ssh_string_fields(_take($blob, 10, length($blob) - 10), 5) or return undef;
    my ($public_key, $namespace, $reserved, $hash_algorithm, $sig_blob) = @$fields;
    my ($sig_type, $signature) = @{_ssh_string_fields($sig_blob, 2) // []};
    return undef unless $sig_type eq 'ssh-ed25519' && length($signature // '') == 64;
    return {
        public_key => $public_key,
        namespace => $namespace,
        reserved => $reserved,
        hash_algorithm => $hash_algorithm,
        signature => $signature,
    };
}

# Splits SSH wire-format strings (uint32 length prefix each); undef unless exactly $count fit the data
sub _ssh_string_fields ($data, $count = undef) {
    my @fields;
    my $offset = 0;
    while ($offset < length $data) {
        return undef if $offset + 4 > length $data;
        my $len = _u32($data, $offset);
        return undef if $offset + 4 + $len > length $data;
        push @fields, _take($data, $offset + 4, $len);
        $offset += 4 + $len;
    }
    return undef if defined $count && @fields != $count;
    return \@fields;
}

sub _take ($data, $offset, $len) { substr $data, $offset, $len }

sub _u32 ($data, $offset) { unpack 'N', _take($data, $offset, 4) }

# DER SubjectPublicKeyInfo wrapping a raw Ed25519 key; the fixed prefix is the
# ASN.1 header for Ed25519 (OID 1.3.101.112) with a 32-byte BIT STRING
sub _ed25519_spki_pem ($raw_key) {
    my $der = pack('H*', '302a300506032b6570032100') . $raw_key;
    return "-----BEGIN PUBLIC KEY-----\n" . encode_base64($der) . "-----END PUBLIC KEY-----\n";
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
