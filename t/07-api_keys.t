#!/usr/bin/env perl
# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";

use OpenQA::Utils;
use OpenQA::Test::Database;
use OpenQA::Test::TimeLimit '10';
use Test::Mojo;
use Test::Warnings ':report_warnings';

OpenQA::Test::Database->new->create(fixtures_glob => '03-users.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');

my $arthur = $t->app->schema->resultset("Users")->find({username => 'arthur'});
my $key = $t->app->schema->resultset("ApiKeys")->create({user_id => $arthur->id});
like($key->key, qr/[0-9a-fA-F]{16}/, 'new keys have a valid random key attribute');
like($key->secret, qr/[0-9a-fA-F]{16}/, 'new keys have a valid random secret attribute');

done_testing();
