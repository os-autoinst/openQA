#!/usr/bin/env perl

# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Mojo::Base -signatures;
use lib 'lib', 't/lib', 'external/os-autoinst-common/lib';
use OpenQA::Schema;
use OpenQA::Test::Database;
use OpenQA::Test::Utils qw(assume_all_assets_exist);

my $schema = OpenQA::Schema::connect_db(mode => 'test', deploy => 0);
my $schema_name = $ENV{OPENQA_DATABASE_SEARCH_PATH} // 'public';

if ($ENV{RESET_SCHEMA}) {
    my $dbh = $schema->storage->dbh;
    $dbh->do('SET client_min_messages TO WARNING');
    $dbh->do("DROP SCHEMA IF EXISTS \"$schema_name\" CASCADE");
    $dbh->do("CREATE SCHEMA \"$schema_name\"");
}

# Deploy schema and insert fixtures
OpenQA::Test::Database->new->create(
    skip_schema => 1,
    fixtures_glob => $ENV{FIXTURES_GLOB} // '*.pl',
);

# Configure mock assets to avoid 404s/warnings
assume_all_assets_exist();
