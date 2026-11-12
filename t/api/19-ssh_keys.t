#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Mojo;
use Test::Warnings ':report_warnings';
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use File::Temp 'tempdir';
use Mojo::File 'path';
use OpenQA::Test::Utils 'generate_ssh_key';
use OpenQA::SSHKey qw(parse_public_key);
use OpenQA::Test::TimeLimit '8';
use OpenQA::Client;
use OpenQA::Test::Case;

OpenQA::Test::Case->new->init_data(fixtures_glob => '0{1-jobs,3-users}.pl');

my $t = Test::Mojo->new('OpenQA::WebAPI');
my $app = $t->app;
$t->ua(OpenQA::Client->new(apikey => 'ARTHURKEY01', apisecret => 'EXCALIBUR')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

my $dir = tempdir(CLEANUP => 1);
my $public_key = generate_ssh_key("$dir/id");
my $parsed = parse_public_key($public_key);

subtest 'list ssh keys is empty for a user without keys' => sub {
    $t->get_ok('/api/v1/users/me/ssh_keys')->status_is(200, 'list ssh keys')->json_is('/keys' => [], 'no keys listed');
};

subtest 'add ssh key' => sub {
    $t->post_ok('/api/v1/users/me/ssh_keys' => form => {public_key => $public_key, title => 'laptop'})
      ->status_is(200, 'valid public key is added')->json_is('/title' => 'laptop', 'title is returned')
      ->json_is('/fingerprint' => $parsed->{fingerprint}, 'fingerprint is returned');
    my $id = $t->tx->res->json->{id};
    $t->get_ok('/api/v1/users/me/ssh_keys')->json_is(
        '/keys/0/fingerprint' => $parsed->{fingerprint},
        'added key is listed'
    );
    ok $id, 'id of the created key is returned';
};

subtest 'invalid input is rejected' => sub {
    $t->post_ok('/api/v1/users/me/ssh_keys' => form => {public_key => 'not a key', title => 'x'})
      ->status_is(400, 'malformed public key is rejected');
    $t->post_ok('/api/v1/users/me/ssh_keys' => form => {public_key => $public_key})
      ->status_is(400, 'missing title is rejected');
    $t->post_ok('/api/v1/users/me/ssh_keys' => form => {public_key => $public_key, title => 'dup'})
      ->status_is(409, 'key already registered to a user is rejected');
};

subtest 'title length limit' => sub {
    my $ok = 'x' x 255;
    $t->post_ok('/api/v1/users/me/ssh_keys' => form => {public_key => $public_key, title => $ok})
      ->status_is(409, 'title at the limit passes validation, key is then reported as already registered');
    $t->post_ok('/api/v1/users/me/ssh_keys' => form => {public_key => $public_key, title => 'x' x 256})
      ->status_is(400, 'title over the limit is rejected');
};

subtest 'delete ssh key' => sub {
    my $id = $t->get_ok('/api/v1/users/me/ssh_keys')->tx->res->json->{keys}[0]{id};
    $t->delete_ok("/api/v1/users/me/ssh_keys/$id")->status_is(200, 'key is deleted');
    $t->get_ok('/api/v1/users/me/ssh_keys')->json_is('/keys' => [], 'no keys after deletion');
    $t->delete_ok("/api/v1/users/me/ssh_keys/$id")->status_is(404, 'deleting an unknown key returns 404');
};

done_testing();
