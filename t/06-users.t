#!/usr/bin/env perl
# Copyright (C) 2014-2020 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";
use OpenQA::Utils;
use OpenQA::Test::Database;
use Test::More;
use Test::Mojo;
use Test::Warnings;

OpenQA::Test::Database->new->create(skip_fixtures => 1);
my $t = Test::Mojo->new('OpenQA::WebAPI');

subtest 'new users are not ops and admins' => sub {
    my $mordred_id = 'https://openid.badguys.uk/mordred';
    my $user       = $t->app->schema->resultset('Users')->create({username => $mordred_id});
    ok(!$user->is_admin,    'new users are not admin by default');
    ok(!$user->is_operator, 'new users are not operator by default');
};

subtest 'system user presence' => sub {
    my $system_user = $t->app->schema->resultset("Users")->search({username => 'system'})->first;
    ok($system_user,               'system user exists');
    ok(!$system_user->is_admin,    'system user is not an admin');
    ok(!$system_user->is_operator, 'system user is not an operator');
    is($system_user->email, 'noemail@open.qa', 'system user`s email uses open.qa domain');
};

subtest 'new user is admin if no admin is present' => sub {
    my $users  = $t->app->schema->resultset('Users');
    my $admins = $users->search({is_admin => 1});
    while (my $u = $admins->next) {
        $u->update({is_admin => 0});
    }
    ok(!$users->search({is_admin => 1})->all, 'no admin is present');
    my $user = $users->create_user('test_user');
    ok($user->is_admin,    'new user is admin by default if there was no admin');
    ok($user->is_operator, 'new user is operator by default if there was no admin');
};

done_testing();
