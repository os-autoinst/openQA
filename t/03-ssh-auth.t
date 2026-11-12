#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use File::Temp 'tempdir';
use Mojo::File 'path';
use OpenQA::SSHKey qw(parse_public_key signature_payload sign_payload);
use OpenQA::Test::TimeLimit '10';
use OpenQA::Test::Case;
use Mojo::Base -signatures;
use Test::Mojo;
use Test::Warnings ':report_warnings';
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
    system('ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', $file) == 0 or die 'ssh-keygen failed';
    ($_ => {private => $file, parsed => parse_public_key(path("$file.pub")->slurp)});
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
    my $payload = signature_payload($path, $timestamp, $body);
    my $signature = sign_payload($keys{$user}{private}, $opts{signed_payload} // $payload);
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
        my $headers = ssh_headers($user, $operator_route, body => $body);
        $t->post_ok($operator_route, {%$headers, 'Content-Type' => 'application/json'}, $body);
    };
    $post->('arthur')->status_isnt(403, 'operator passes the operator gate via SSH')
      ->json_has('/error', 'controller handles the request after auth');
    $post->('lancelot')->status_is(403, 'non-operator with a valid SSH key is denied on operator route');
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
    my $headers = ssh_headers('arthur', $operator_route, body => '{}');
    $t->post_ok($operator_route, {%$headers, 'Content-Type' => 'application/json'}, '{"tampered":1}')
      ->status_is(403, 'signature over a different body is rejected');
};

subtest 'mixing SSH and API-key headers is rejected' => sub {
    my $headers = {%{ssh_headers('arthur', $whoami)}, 'X-API-Key' => 'ARTHURKEY01', 'X-API-Hash' => 'x'};
    $t->get_ok($whoami, $headers)->status_is(403, 'request carrying both auth schemes is rejected')
      ->json_is('/error', 'SSH and API key authentication cannot be combined', 'rejection names the conflict');
};

done_testing();
