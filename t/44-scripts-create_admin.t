#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;
use Test::Warnings ':report_warnings';

use FindBin '$Bin';
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '10';
use OpenQA::Test::Database;

my $schema_name = OpenQA::Test::Database::generate_schema_name;
my $schema = OpenQA::Test::Database->new->create(schema_name => $schema_name);
my $users = $schema->resultset('Users');

$ENV{OPENQA_DATABASE} = 'test';
$ENV{OPENQA_DATABASE_SEARCH_PATH} = $schema_name;

sub all_users () {
    [sort map { $_->username } $users->search({})->all]
}

is_deeply all_users, [qw(system)], 'only system user initially present';

my $cmd = "$Bin/../script/create_admin";
my $output = qx{"$cmd" test-user --email test-email --nickname test-nick --fullname test-full 2>&1};
is $?, 0, 'command exited with zero return code';
note "output: $output";

ok my $new_user = $users->find({username => 'test-user'}), 'new user created'
  or BAIL_OUT 'unexpected set users present: ' . always_explain all_users;
is $new_user->email, 'test-email', 'e-mail set';
is $new_user->nickname, 'test-nick', 'nickname set';
is $new_user->fullname, 'test-full', 'fullname set';
is $new_user->api_keys->count, 1, 'API keys created';

subtest 'attempt to create 2nd admin' => sub {
    my $output = qx{"$cmd" test-user2 --email test-email2 --nickname test-nick2 --fullname test-full2 2>&1};
    is $? >> 8, 1, 'command exited with return code 1';
    is_deeply all_users, [qw(system test-user)], 'creation of 2nd admin prevented';
    like $output, qr/already exists/i, 'expected explanation';
};

subtest 'attempt to supply an invalid key/secret' => sub {
    my $output = qx{"$cmd" test-user2 --key foo --secret bar 2>&1};
    is $? >> 8, 255, 'command exited with return code 255';
    like $output, qr/must.*be.*hexadecimals/i, 'expected explanation';
};

done_testing;
