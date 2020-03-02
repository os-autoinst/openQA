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

OpenQA::Test::Database->new->create();
my $t = Test::Mojo->new('OpenQA::WebAPI');


my $arthur = $t->app->schema->resultset("Users")->find({username => 'arthur'});
my $key    = $t->app->schema->resultset("ApiKeys")->create({user_id => $arthur->id});
like($key->key,    qr/[0-9a-fA-F]{16}/, 'new keys have a valid random key attribute');
like($key->secret, qr/[0-9a-fA-F]{16}/, 'new keys have a valid random secret attribute');

done_testing();
