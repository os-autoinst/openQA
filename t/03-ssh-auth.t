#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use File::Temp 'tempdir';
use Mojo::File 'path';
use OpenQA::Test::Utils 'generate_ssh_key';
use OpenQA::SSHKey qw(parse_public_key signature_payload sign_payload);
use OpenQA::Test::TimeLimit '10';
use OpenQA::Test::Case;
use Mojo::Base -signatures;
use Test::Mojo;
use Test::Warnings ':report_warnings';
use Test::Output 'combined_like';
use Time::Seconds;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data(fixtures_glob => '03-users.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');
my $schema = $t->app->schema;
my $arthur = $schema->resultset('Users')->find({username => 'arthur'});
my $lancelot = $schema->resultset('Users')->find({username => 'https://openid.camelot.uk/lancelot'});

my $dir = tempdir(CLEANUP => 1);
my %keys = map {
    my $file = "$dir/$_";
    ($_ => {private => $file, parsed => parse_public_key(generate_ssh_key($file))});
} qw(arthur lancelot);

$arthur->ssh_keys->create(
    {
        public_key => $keys{arthur}{parsed}{public_key},
        fingerprint => $keys{arthur}{parsed}{fingerprint},
        title => 'arthur laptop',
    });
$lancelot->ssh_keys->create(
    {
        public_key => $keys{lancelot}{parsed}{public_key},
        fingerprint => $keys{lancelot}{parsed}{fingerprint},
        title => 'lancelot laptop',
    });

sub ssh_headers ($user, $path, %opts) {
    my $timestamp = $opts{timestamp} // time;
    my $body = $opts{body} // '';
    my $payload = signature_payload($opts{method} // 'GET', $path, $timestamp, $body);
    my $signature = sign_payload($keys{$user}{private}, $payload);
    return {
        'X-SSH-Key-Fingerprint' => $keys{$user}{parsed}{fingerprint},
        'X-SSH-Microtime' => $timestamp,
        'X-SSH-Signature' => $signature,
    };
}

my $whoami = '/api/v1/auth';
my $operator_route = '/api/v1/jobs';

subtest 'valid signature authenticates' => sub {
    $t->get_ok($whoami, ssh_headers('arthur', $whoami))->status_is(200, 'user authenticated via SSH signature');
    my $key = $arthur->ssh_keys->first;
    ok $key->discard_changes->last_used, 'last_used is recorded on successful SSH authentication';
};

subtest 'operator route enforces operator rights for SSH auth' => sub {
    my $body = '{}';
    my $post = sub ($user) {
        my $headers = ssh_headers($user, $operator_route, method => 'POST', body => $body);
        $t->post_ok($operator_route, {%$headers, 'Content-Type' => 'application/json'}, $body);
    };
    $post->('arthur')->status_isnt(403, 'operator passes the operator gate via SSH')
      ->json_has('/error', 'controller handles the request after auth');
    $post->('lancelot')->status_is(403, 'non-operator with a valid SSH key is denied on operator route');
};

subtest 'forward auth verifies the signature over X-Original-URI' => sub {
    my $original = '/api/v1/jobs?limit=2';
    my $headers = ssh_headers('arthur', $original);
    $t->get_ok($whoami, {%$headers, 'X-Original-URI' => $original})
      ->status_is(200, 'signature over the original request target is accepted');
};

subtest 'signature is bound to the HTTP method' => sub {
    my $headers = ssh_headers('arthur', $operator_route, method => 'GET');
    $t->post_ok($operator_route, {%$headers, 'Content-Type' => 'application/json'}, '{}')
      ->status_is(403, 'GET signature is rejected for a POST to the same path')
      ->json_is('/error', 'invalid SSH signature', 'rejection is the signature check');
};

subtest 'multipart bodies cannot be authenticated by SSH signature' => sub {
    my $headers = ssh_headers('arthur', $operator_route, method => 'POST', body => '');
    $t->post_ok($operator_route, {%$headers}, form => {artefact => {content => 'uploaded bytes'}})
      ->status_is(403, 'multipart request with an empty-body signature is rejected')
      ->json_is('/error', 'SSH signatures cannot cover multipart bodies', 'rejection names multipart');
};

subtest 'rejected SSH signature is logged with its cause' => sub {
    my $headers = {%{ssh_headers('arthur', $whoami)}, 'X-SSH-Signature' => 'garbage'};
    combined_like { $t->get_ok($whoami, $headers)->status_is(403) }
    qr/Invalid SSH signature for user "arthur"/, 'debug log names the user whose signature failed';
};

subtest 'unknown SSH fingerprint is logged' => sub {
    my $headers = {%{ssh_headers('arthur', $whoami)}, 'X-SSH-Key-Fingerprint' => 'SHA256:nobody'};
    combined_like { $t->get_ok($whoami, $headers)->status_is(403) }
    qr/Unknown SSH key fingerprint/, 'debug log names the unknown fingerprint';
};

subtest 'invalid SSH authentication is rejected' => sub {
    my %cases = (
        'signature for another path' => ssh_headers('arthur', '/api/v1/jobs/1'),
        'stale timestamp' => ssh_headers('arthur', $whoami, timestamp => time - ONE_HOUR),
        'missing timestamp' => do { my %h = %{ssh_headers('arthur', $whoami)}; delete $h{'X-SSH-Microtime'}; \%h },
        'unknown fingerprint' => {%{ssh_headers('arthur', $whoami)}, 'X-SSH-Key-Fingerprint' => 'SHA256:unknown'},
        'malformed signature' => {%{ssh_headers('arthur', $whoami)}, 'X-SSH-Signature' => 'garbage'},
        'signature of another key' => {
            %{ssh_headers('arthur', $whoami)},
            'X-SSH-Signature' => ssh_headers('lancelot', $whoami)->{'X-SSH-Signature'}
        },
    );
    for my $desc (sort keys %cases) {
        $t->get_ok($whoami, $cases{$desc})->status_is(403, "$desc is rejected");
    }
};

subtest 'body must match the signed payload' => sub {
    my $headers = ssh_headers('arthur', $operator_route, method => 'POST', body => '{}');
    $t->post_ok($operator_route, {%$headers, 'Content-Type' => 'application/json'}, '{"tampered":1}')
      ->status_is(403, 'signature over a different body is rejected');
};

subtest 'mixing SSH headers with a bearer token is rejected' => sub {
    my $headers = {%{ssh_headers('arthur', $whoami)}, Authorization => 'Bearer arthur:ARTHURKEY01:EXCALIBUR'};
    $t->get_ok($whoami, $headers)->status_is(403, 'request carrying SSH and bearer auth is rejected')
      ->json_is('/error', 'SSH and API key authentication cannot be combined', 'rejection names the conflict');
};

subtest 'an empty SSH fingerprint header still counts as an SSH request' => sub {
    my $headers = {
        %{ssh_headers('arthur', $whoami)},
        'X-SSH-Key-Fingerprint' => '',
        'X-API-Key' => 'ARTHURKEY01',
        'X-API-Hash' => 'x'
    };
    $t->get_ok($whoami, $headers)->status_is(403, 'empty fingerprint with an API key is rejected')
      ->json_is('/error', 'SSH and API key authentication cannot be combined', 'rejection names the conflict');
};

subtest 'mixing SSH and API-key headers is rejected' => sub {
    my $headers = {%{ssh_headers('arthur', $whoami)}, 'X-API-Key' => 'ARTHURKEY01', 'X-API-Hash' => 'x'};
    $t->get_ok($whoami, $headers)->status_is(403, 'request carrying both auth schemes is rejected')
      ->json_is('/error', 'SSH and API key authentication cannot be combined', 'rejection names the conflict');
};

done_testing();
