#!/usr/bin/env perl
# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Utils;
require OpenQA::Test::Database;
use OpenQA::Test::TimeLimit '10';
use Test::Mojo;
use Test::Warnings ':report_warnings';

OpenQA::Test::Database->new->create;
my $t = Test::Mojo->new('OpenQA::WebAPI');
my $users = $t->app->schema->resultset('Users');

subtest 'new users are not ops and admins' => sub {
    my $mordred_id = 'https://openid.badguys.uk/mordred';
    my $user = $users->create({username => $mordred_id});
    ok !$user->is_admin, 'new users are not admin by default';
    ok !$user->is_operator, 'new users are not operator by default';
};

subtest 'system user presence' => sub {
    my $system_user = $users->system;
    ok $system_user, 'system user exists';
    ok !$system_user->is_admin, 'system user is not an admin';
    ok !$system_user->is_operator, 'system user is not an operator';
    is $system_user->email, 'noemail@open.qa', 'system user`s email uses open.qa domain';
};

subtest 'new user is admin if no admin is present' => sub {
    my $admins = $users->search({is_admin => 1});
    while (my $admin = $admins->next) { $admin->update({is_admin => 0}) }
    ok !$users->search({is_admin => 1})->all, 'no admin is present';
    my $user = $users->create_user('test_user');
    ok $user->is_admin, 'new user is admin by default if there was no admin';
    ok $user->is_operator, 'new user is operator by default if there was no admin';
};

subtest 'gravatar URL' => sub {
    my $user = $users->create({username => 'user-without-e-mail'});
    is $user->gravatar, '//www.gravatar.com/avatar?s=40', 'without e-mail';
    like $users->find(1)->gravatar, qr|//www.gravatar.com/avatar/[a-f0-9]{32}\?d=wavatar&s=40|, 'with e-mail';
};

subtest 'auth provider mismatch' => sub {
    $users->create_user('collision_user', provider => '');
    ok $users->find({username => 'collision_user', provider => ''}), 'initial user created';
    throws_ok { $users->create_user('collision_user', provider => 'oauth2@github') }
    qr/Auth provider mismatch: Account 'collision_user' is registered via 'default'/,
      'throws error on provider mismatch';
    lives_ok { $users->create_user('collision_user', provider => '') } 'works if provider matches existing one';
};

done_testing();
