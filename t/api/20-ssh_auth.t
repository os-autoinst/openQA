#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::MockModule;
use Test::Mojo;
use Test::Warnings qw(:all :report_warnings);
use OpenQA::Test::TimeLimit '10';
use OpenQA::Test::Case;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data(fixtures_glob => '03-users.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');
my $schema = $t->app->schema;

my $pubkey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOc4Q2m2F2s5Z1pV0aV1pV1pV1pV1pV1pV1pV1pV1pV1 mykey';
my $fingerprint = OpenQA::Schema::Result::SshKeys::fingerprint_for($pubkey);
ok $fingerprint, 'fingerprint computed from public key';

subtest 'creating ssh key via UI requires login' => sub {
    $t->get_ok('/ssh_keys')->status_is(302, 'ssh keys page redirects when not logged in');
    $t->post_ok('/ssh_keys', form => {title => 'k', public_key => $pubkey})
      ->status_is(302, 'create redirects when not logged in');
    is $schema->resultset('SshKeys')->count, 0, 'no key created without login';
};

subtest 'adding and listing ssh key' => sub {
    $t->get_ok('/tests');
    my $token = $t->tx->res->dom->at('meta[name=csrf-token]')->attr('content');
    $test_case->login($t, 'percival');

    $t->post_ok('/ssh_keys', {'X-CSRF-Token' => $token} => form => {title => 'my key', public_key => $pubkey})
      ->status_is(302, 'valid key redirects');
    $t->get_ok('/ssh_keys')->status_is(200)->element_exists('#ssh_key_1', 'created key listed')
      ->text_is('#ssh_key_1 .title', 'my key', 'title shown')
      ->text_is('#ssh_key_1 .public_key', $pubkey, 'public key shown');

    $t->post_ok('/ssh_keys', {'X-CSRF-Token' => $token} => form => {title => 'bad', public_key => 'not a key'})
      ->status_is(302, 'invalid key redirects');
    $t->get_ok('/ssh_keys')->status_is(200)->element_exists_not('#ssh_key_2', 'invalid key not created')
      ->element_exists('#flash-messages .alert-danger', 'invalid key shows error');

    $t->post_ok('/ssh_keys', {'X-CSRF-Token' => $token} => form => {title => 'no pub'})
      ->status_is(302, 'missing public key redirects');
    $t->get_ok('/ssh_keys')->status_is(200)
      ->element_exists('#flash-messages .alert-danger', 'missing public key error');

    $t->post_ok('/ssh_keys', {'X-CSRF-Token' => $token} => form => {title => '', public_key => $pubkey})
      ->status_is(302, 'empty title redirects');
    $t->get_ok('/ssh_keys')->status_is(200)->element_exists('#flash-messages .alert-danger', 'empty title shows error');

    $t->post_ok(
        '/ssh_keys',
        {'X-CSRF-Token' => $token} => form => {
            title => 'key w exp',
            public_key => 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOc4Q2m2F2s5Z1pV0aV1pV1pV1pV1pV1pV1pV1pV1pV2 key2',
            t_expiration => '2028-01-01 12:00:00'
        })->status_is(302, 'key with expiration redirects');
};

subtest 'ssh key auth via api' => sub {
    $t->ua->cookie_jar->empty;
    my $key = $schema->resultset('SshKeys')->find({title => 'my key'});
    ok $key, 'key stored for percival';
    is $key->user->username, 'percival', 'key belongs to percival';
    is $key->pubic_key, $pubkey, 'pubic_key alias returns public key';

    my $auth_mock = Test::MockModule->new('OpenQA::Shared::Controller::Auth');
    $auth_mock->redefine(_ssh_signature_valid => sub { 1 });

    $t->get_ok('/api/v1/users/me/api_keys',
        {'X-SSH-Signature' => 'sig', 'X-SSH-Key-Fingerprint' => $key->fingerprint, 'X-API-Microtime' => time})
      ->status_is(200, 'valid ssh signature authorizes the request');
    $key->discard_changes;
    ok $key->last_used, 'last_used updated on successful auth';

    $auth_mock->redefine(_ssh_signature_valid => sub { 0 });
    $t->get_ok('/api/v1/users/me/api_keys',
        {'X-SSH-Signature' => 'sig', 'X-SSH-Key-Fingerprint' => $key->fingerprint, 'X-API-Microtime' => time})
      ->status_is(403, 'invalid ssh signature rejected');

    $t->get_ok('/api/v1/users/me/api_keys',
        {'X-SSH-Signature' => 'sig', 'X-SSH-Key-Fingerprint' => 'SHA256:doesnotexist', 'X-API-Microtime' => time})
      ->status_is(403, 'unknown fingerprint rejected');

    undef $auth_mock;

    $t->get_ok('/api/v1/users/me/api_keys',
        {'X-SSH-Signature' => 'sig', 'X-SSH-Key-Fingerprint' => $key->fingerprint, 'X-API-Microtime' => 1})
      ->status_is(403, 'timestamp mismatch rejected');

    $t->get_ok('/api/v1/users/me/api_keys',
        {'X-SSH-Signature' => 'bogus', 'X-SSH-Key-Fingerprint' => $key->fingerprint, 'X-API-Microtime' => time})
      ->status_is(403, 'real signature check fails on bogus signature');
};

subtest 'expired ssh key is rejected' => sub {
    my $key = $schema->resultset('SshKeys')->find({title => 'my key'});
    $key->update({t_expiration => DateTime->from_epoch(epoch => time - 7200)});
    my $auth_mock = Test::MockModule->new('OpenQA::Shared::Controller::Auth');
    $auth_mock->redefine(_ssh_signature_valid => sub { 1 });
    $t->get_ok('/api/v1/users/me/api_keys',
        {'X-SSH-Signature' => 'sig', 'X-SSH-Key-Fingerprint' => $key->fingerprint, 'X-API-Microtime' => time})
      ->status_is(403, 'expired ssh key rejected');
    undef $auth_mock;
};

subtest 'deleting ssh key' => sub {
    $t->get_ok('/tests');
    my $token = $t->tx->res->dom->at('meta[name=csrf-token]')->attr('content');
    $test_case->login($t, 'percival');
    $t->delete_ok('/ssh_keys/999', {'X-CSRF-Token' => $token})->status_is(302, 'deleting non-existent key redirects');
    $t->get_ok('/ssh_keys')->status_is(200)
      ->element_exists('#flash-messages .alert-danger', 'error message on missing key');
    $t->delete_ok('/ssh_keys/1', {'X-CSRF-Token' => $token})->status_is(302, 'delete redirects');
    $t->get_ok('/ssh_keys')->status_is(200)->element_exists_not('#ssh_key_1', 'ssh key gone');
    is $schema->resultset('SshKeys')->count, 1, 'one ssh key remains in db';
};

subtest 'client ssh signing and headers' => sub {
    require OpenQA::UserAgent;
    use Mojo::File qw(tempfile);
    my $headers = Mojo::Headers->new;
    OpenQA::UserAgent::add_auth_headers($headers, Mojo::URL->new('http://localhost/test'),
        undef, undef, '/nonexistent/key');
    is $headers->header('X-SSH-Signature'), undef, 'no signature added for invalid key';

    my $tmp = tempfile;
    my $keyfile = "$tmp.key";
    system 'ssh-keygen', '-q', '-N', '', '-t', 'ed25519', '-f', $keyfile;
    if (-f $keyfile) {
        $headers = Mojo::Headers->new;
        OpenQA::UserAgent::add_auth_headers($headers, Mojo::URL->new('http://localhost/test'), undef, undef, $keyfile);
        ok $headers->header('X-SSH-Signature'), 'signature generated with real key';
        like $headers->header('X-SSH-Key-Fingerprint'), qr/^SHA256:/, 'fingerprint generated with real key';
        unlink $keyfile, "$keyfile.pub";
    }

    my $ua = OpenQA::UserAgent->new(sshkey => '/path/to/key');
    is $ua->sshkey, '/path/to/key', 'sshkey attribute initialized';
};

done_testing();
