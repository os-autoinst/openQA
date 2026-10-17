#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";

use OpenQA::Utils;
require OpenQA::Test::Database;
use OpenQA::Test::TimeLimit '10';
use Test::Mojo;
use Test::Warnings ':report_warnings';

OpenQA::Test::Database->new->create(fixtures_glob => '03-users.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');

my $arthur = $t->app->schema->resultset('Users')->find({username => 'arthur'});
my $key = $t->app->schema->resultset('ApiKeys')->create({user_id => $arthur->id});
like $key->key, qr/[0-9a-fA-F]{16}/, 'new keys have a valid random key attribute';
like $key->secret, qr/[0-9a-fA-F]{16}/, 'new keys have a valid random secret attribute';
is $key->comment, undef, 'api key created without comment has undefined comment';

my $commented_key = $t->app->schema->resultset('ApiKeys')->create({user_id => $arthur->id, comment => 'test key'});
is $commented_key->comment, 'test key', 'api key created with comment stores and returns the comment';

done_testing();
