#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use File::Temp 'tempdir';
use Mojo::File 'path';
use OpenQA::Test::Utils 'generate_ssh_key';
use OpenQA::SSHKey qw(parse_public_key);
use OpenQA::Test::TimeLimit '8';
use OpenQA::Test::Case;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data(fixtures_glob => '03-users.pl');

my $t = Test::Mojo->new('OpenQA::WebAPI');
my $schema = $t->app->schema;

my $dir = tempdir(CLEANUP => 1);
my $public_key = generate_ssh_key("$dir/id");
my $parsed = parse_public_key($public_key);

$t->get_ok('/api_keys')->status_is(302, 'api keys page requires login');

$t->get_ok('/tests');
my $token = $t->tx->res->dom->at('meta[name=csrf-token]')->attr('content');
$test_case->login($t, 'percival');

subtest 'SSH keys section is shown on the API keys page' => sub {
    $t->get_ok('/api_keys')->status_is(200)->element_exists('#ssh-key-form', 'form to add an SSH key is shown')
      ->element_exists('#ssh-key-public-key', 'public key input is present')
      ->element_exists('#ssh-key-title', 'title input is present')
      ->element_exists('#ssh-keys-tbody', 'ssh key table is present');
};

subtest 'adding an SSH key lists it for the user' => sub {
    $t->post_ok('/ssh_keys', {'X-CSRF-Token' => $token} => form => {public_key => $public_key, title => 'work laptop'})
      ->status_is(302, 'valid key redirects back');
    my $key = $schema->resultset('SshKeys')->find({fingerprint => $parsed->{fingerprint}});
    ok $key, 'key is stored in the database';
    is $key->user->username, 'percival', 'key belongs to the logged in user';
    $t->get_ok('/api_keys')->status_is(200, 'api keys page displays')
      ->text_is("#ssh_key_@{[$key->id]} .title" => 'work laptop', 'title is listed')
      ->text_is("#ssh_key_@{[$key->id]} .fingerprint" => $parsed->{fingerprint}, 'fingerprint is listed');
};

subtest 'invalid SSH key is rejected with an error' => sub {
    $t->post_ok('/ssh_keys', {'X-CSRF-Token' => $token} => form => {public_key => 'junk', title => 'x'})
      ->status_is(302, 'invalid key redirects back');
    $t->get_ok('/api_keys')->status_is(200)->element_exists('#flash-messages .alert-danger', 'error is displayed');
};

subtest 'SSH key without title is rejected' => sub {
    $t->post_ok('/ssh_keys', {'X-CSRF-Token' => $token} => form => {public_key => $public_key})
      ->status_is(302, 'missing title redirects back');
    $t->get_ok('/api_keys')->status_is(200)
      ->content_like(qr/A public key and a title are required/, 'missing title error is displayed');
};

subtest 'SSH key already registered is rejected' => sub {
    $t->post_ok('/ssh_keys', {'X-CSRF-Token' => $token} => form => {public_key => $public_key, title => 'again'})
      ->status_is(302, 'duplicate key redirects back');
    $t->get_ok('/api_keys')->status_is(200)
      ->content_like(qr/This SSH key is already registered/, 'duplicate key error is displayed');
};

subtest 'deleting an SSH key removes it' => sub {
    my $key = $schema->resultset('SshKeys')->find({fingerprint => $parsed->{fingerprint}});
    $t->delete_ok('/ssh_keys/' . $key->id, {'X-CSRF-Token' => $token})->status_is(302, 'delete redirects back');
    $t->get_ok('/api_keys')->status_is(200)->element_exists_not("#ssh_key_@{[$key->id]}", 'deleted key is gone');
};

subtest 'deleting with a non-numeric id is not found' => sub {
    $t->delete_ok('/ssh_keys/not-a-number', {'X-CSRF-Token' => $token})
      ->status_is(404, 'non-numeric id does not reach the database');
};

subtest 'users cannot delete SSH keys of other users' => sub {
    my $lancelot = $schema->resultset('Users')->find({username => 'https://openid.camelot.uk/lancelot'});
    my $foreign = $lancelot->ssh_keys->create(
        {public_key => $parsed->{public_key}, fingerprint => 'SHA256:foreign', title => 'foreign'});
    $t->delete_ok('/ssh_keys/' . $foreign->id, {'X-CSRF-Token' => $token})->status_is(302, 'delete redirects back');
    ok $foreign->in_storage, 'key of another user is not deleted';
};

done_testing();
