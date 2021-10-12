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

OpenQA::Test::Database->new->create;
my $t = Test::Mojo->new('OpenQA::WebAPI');

subtest 'new users are not ops and admins' => sub {
    my $mordred_id = 'https://openid.badguys.uk/mordred';
    my $user = $t->app->schema->resultset('Users')->create({username => $mordred_id});
    ok(!$user->is_admin, 'new users are not admin by default');
    ok(!$user->is_operator, 'new users are not operator by default');
};

subtest 'system user presence' => sub {
    my $system_user = $t->app->schema->resultset("Users")->search({username => 'system'})->first;
    ok($system_user, 'system user exists');
    ok(!$system_user->is_admin, 'system user is not an admin');
    ok(!$system_user->is_operator, 'system user is not an operator');
    is($system_user->email, 'noemail@open.qa', 'system user`s email uses open.qa domain');
};

subtest 'new user is admin if no admin is present' => sub {
    my $users = $t->app->schema->resultset('Users');
    my $admins = $users->search({is_admin => 1});
    $_->update({is_admin => 0}) while $admins->next;
    ok(!$users->search({is_admin => 1})->all, 'no admin is present');
    my $user = $users->create_user('test_user');
    ok($user->is_admin, 'new user is admin by default if there was no admin');
    ok($user->is_operator, 'new user is operator by default if there was no admin');
};

done_testing();
