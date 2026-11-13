#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Utils;
require OpenQA::Test::Database;
use OpenQA::Test::TimeLimit '10';
use Test::Mojo;
use Test::Warnings ':report_warnings';

OpenQA::Test::Database->new->create(fixtures_glob => '03-users.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');
my $schema = $t->app->schema;
my $arthur = $schema->resultset('Users')->find({username => 'arthur'});
my $ssh_keys = $schema->resultset('SshKeys');
my $public_key = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyMaterialForTestingOnly arthur@test';

subtest 'create ssh key with fingerprint and title' => sub {
    my $key = $ssh_keys->create(
        {user_id => $arthur->id, public_key => $public_key, fingerprint => 'SHA256:abc', title => 'laptop'});
    is $key->user->username, 'arthur', 'ssh key belongs to its user';
    is $key->title, 'laptop', 'title is stored';
    is $arthur->ssh_keys->count, 1, 'user has the ssh key';
};

subtest 'fingerprint is unique' => sub {
    throws_ok {
        $ssh_keys->create(
            {user_id => $arthur->id, public_key => $public_key, fingerprint => 'SHA256:abc', title => 'copy'});
    }
    qr/ssh_keys_fingerprint/, 'duplicate fingerprint violates the unique constraint';
};

subtest 'anonymizing a user deletes their ssh keys' => sub {
    $arthur->anonymize;
    is $ssh_keys->search({user_id => $arthur->id})->count, 0, 'ssh keys are removed on anonymization';
};

done_testing();
