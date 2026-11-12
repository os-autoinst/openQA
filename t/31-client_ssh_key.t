#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use File::Temp 'tempdir';
use Mojo::File 'path';
use Mojo::Headers;
use Mojo::URL;
use OpenQA::UserAgent;
use OpenQA::Test::Utils 'generate_ssh_key';
use OpenQA::SSHKey qw(parse_public_key signature_payload verify_signature);
use OpenQA::Test::TimeLimit '10';
use Test::Warnings ':report_warnings';

my $dir = tempdir(CLEANUP => 1);
my $parsed = parse_public_key(generate_ssh_key("$dir/id"));

subtest 'ssh key signs the request path, timestamp and body' => sub {
    my $headers = Mojo::Headers->new;
    my $url = Mojo::URL->new('/api/v1/jobs?limit=2');
    OpenQA::UserAgent::add_ssh_auth_headers($headers, 'POST', $url, "$dir/id", '{"a":1}');
    is $headers->header('X-SSH-Key-Fingerprint'), $parsed->{fingerprint}, 'fingerprint of the key is sent';
    my $timestamp = $headers->header('X-SSH-Microtime');
    like $timestamp, qr/^\d+$/, 'timestamp is sent';
    my $payload = signature_payload('POST', '/api/v1/jobs?limit=2', $timestamp, '{"a":1}');
    ok verify_signature($parsed->{public_key}, $payload, $headers->header('X-SSH-Signature')),
      'signature verifies over path, timestamp and body';
};

subtest 'missing SSH key file fails with a clear error' => sub {
    throws_ok {
        OpenQA::UserAgent::add_ssh_auth_headers(Mojo::Headers->new, 'GET', Mojo::URL->new('/api/v1/jobs'),
            "$dir/missing", '')
    }
    qr{SSH key "$dir/missing" .*cannot be read}, 'error names the unreadable key file';
};

subtest 'failing ssh-keygen surfaces its reason' => sub {
    path("$dir/notakey")->spew("garbage\n");
    path("$dir/notakey.pub")->spew($parsed->{public_key} . "\n");
    throws_ok {
        OpenQA::UserAgent::add_ssh_auth_headers(Mojo::Headers->new, 'GET', Mojo::URL->new('/api/v1/jobs'),
            "$dir/notakey", '')
    }
    qr/Signing with SSH key .* failed: .+/, 'signing failure reports the ssh-keygen reason';
};

subtest 'multipart request is refused rather than signed with an empty body' => sub {
    my $ua = OpenQA::UserAgent->new(ssh_key => "$dir/id");
    my $tx = $ua->build_tx(POST => 'http://localhost/api/v1/jobs' => form => {artefact => {content => 'bytes'}});
    throws_ok {
        $ua->start($tx => sub { })
    }
    qr/cannot sign multipart requests/, 'multipart upload is refused';
};

subtest 'ssh key takes precedence over a configured API key' => sub {
    my $ua = OpenQA::UserAgent->new(apikey => 'CONFIGKEY', apisecret => 'CONFIGSECRET', ssh_key => "$dir/id");
    my $tx = $ua->build_tx(GET => 'http://localhost/api/v1/jobs');
    $ua->start($tx => sub { });
    is $tx->req->headers->header('X-API-Key'), undef, 'configured API key is not sent when an SSH key is set';
    ok $tx->req->headers->header('X-SSH-Signature'), 'request is signed with the SSH key instead';
};

subtest 'SSH auth does not send API key headers' => sub {
    my $headers = Mojo::Headers->new;
    OpenQA::UserAgent::add_ssh_auth_headers($headers, 'GET', Mojo::URL->new('/api/v1/jobs'), "$dir/id", '');
    is $headers->header('X-API-Key'), undef, 'no API key header';
    is $headers->header('X-API-Hash'), undef, 'no API hash header';
};

subtest 'command client uses the ssh key when configured' => sub {
    require OpenQA::Command;
    my $command = OpenQA::Command->new(ssh_key => "$dir/id");
    my $client = $command->client(Mojo::URL->new('http://localhost'));
    is $client->ssh_key, "$dir/id", 'ssh key is passed to the client';
};

done_testing();
