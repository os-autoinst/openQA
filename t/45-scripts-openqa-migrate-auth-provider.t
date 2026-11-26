#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;
use Test::Warnings ':report_warnings';

use FindBin '$Bin';
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '15';
use OpenQA::Test::Database;

my $cmd = "$Bin/../script/openqa-migrate-auth-provider";

subtest 'usage and option validation' => sub {
    my $help_output = qx{"$cmd" --help 2>&1};
    is $? >> 8, 0, 'exit code 0 on help';
    like $help_output, qr/--to-provider/, 'help documents to-provider';
    like $help_output, qr/--strip-prefix/, 'help documents strip-prefix';
    like $help_output, qr/--dry-run|--apply/, 'help documents apply or dry-run';

    my $missing_output = qx{"$cmd" 2>&1};
    isnt $? >> 8, 0, 'fails when required to-provider is missing';
    like $missing_output, qr/Mandatory parameter.*to_provider/i, 'error indicates missing to-provider';
};

subtest 'dry-run and apply migration workflow' => sub {
    my $schema_name = OpenQA::Test::Database::generate_schema_name;
    my $schema = OpenQA::Test::Database->new->create(schema_name => $schema_name);
    my $users = $schema->resultset('Users');

    local $ENV{OPENQA_DATABASE} = 'test';
    local $ENV{OPENQA_DATABASE_SEARCH_PATH} = $schema_name;

    my $alice = $users->create_user(
        'https://www.opensuse.org/openid/user/alice',
        provider => '',
        email => 'alice@example.com',
        nickname => 'alice',
        fullname => 'Alice Cooper'
    );
    my $bob = $users->create_user(
        'https://www.opensuse.org/openid/user/bob',
        provider => '',
        email => 'bob@example.com',
        nickname => 'bob',
        fullname => 'Bob Builder'
    );
    my $alice_id = $alice->id;
    my $api_key = $alice->api_keys->create({key => '1111222233334444', secret => 'AAAABBBBCCCCDDDD'});

    my $dry_run_output
      = qx{"$cmd" --from-provider "" --to-provider "Local" --strip-prefix "^https://www.opensuse.org/openid/user/" 2>&1};
    is $? >> 8, 0, 'dry-run exits with zero code';
    like $dry_run_output, qr/DRY-RUN mode/, 'dry-run mode acknowledged';
    like $dry_run_output, qr/2 account\(s\) ready to migrate/i, 'dry-run found 2 candidates';

    my $alice_unchanged = $users->find($alice_id);
    is $alice_unchanged->username, 'https://www.opensuse.org/openid/user/alice', 'dry-run leaves username unchanged';
    is $alice_unchanged->provider, '', 'dry-run leaves provider unchanged';

    my $apply_output
      = qx{"$cmd" --from-provider "" --to-provider "Local" --strip-prefix "^https://www.opensuse.org/openid/user/" --apply 2>&1};
    is $? >> 8, 0, 'apply exits with zero code';
    like $apply_output, qr/Successfully migrated 2 user account\(s\) to 'Local'/, 'apply confirms migration count';

    my $alice_migrated = $users->find($alice_id);
    is $alice_migrated->username, 'alice', 'alice username updated';
    is $alice_migrated->provider, 'Local', 'alice provider updated to Local';
    is $alice_migrated->api_keys->first->key, '1111222233334444', 'alice api key preserved via foreign key';

    my $bob_migrated = $users->find($bob->id);
    is $bob_migrated->username, 'bob', 'bob username updated';
    is $bob_migrated->provider, 'Local', 'bob provider updated to Local';

    my $system_user = $users->find({username => 'system'});
    is $system_user->provider, '', 'system user provider preserved';

    $users->create_user(
        'https://www.opensuse.org/openid/user/alice',
        provider => 'other_openid',
        email => 'alice_alt@example.com',
        nickname => 'alice_alt',
    );
    my $conflict_output
      = qx{"$cmd" --from-provider "other_openid" --to-provider "Local" --strip-prefix "^https://www.opensuse.org/openid/user/" --apply 2>&1};
    isnt $? >> 8, 0, 'fails when conflict is detected';
    like $conflict_output, qr/Conflict/i, 'conflict reported in output';
};

done_testing;
