#!/usr/bin/env perl -w

# Copyright (C) 2014 SUSE Linux Products GmbH
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

BEGIN {
    unshift @INC, 'lib', 'lib/OpenQA';
}

use strict;
use OpenQA::Utils;
use OpenQA::Test::Database;
use Test::More;
use Test::Mojo;

OpenQA::Test::Database->new->create();
my $t = Test::Mojo->new('OpenQA');


my $arthur = $t->app->db->resultset("Users")->find({openid => 'https://openid.camelot.uk/arthur'});
my $key = $t->app->db->resultset("ApiKeys")->create({user_id => $arthur->id});
like($key->key, qr/[0-9a-fA-F]{16}/, 'new keys have a valid random key attribute');
like($key->secret, qr/[0-9a-fA-F]{16}/, 'new keys have a valid random secret attribute');

done_testing();
