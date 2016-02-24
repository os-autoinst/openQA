BEGIN { unshift @INC, 'lib'; }

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

use Mojo::Base -strict;

use Test::More 'no_plan';
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Database;

OpenQA::Test::Database->new->create(skip_fixtures => 1);

my $t = Test::Mojo->new('OpenQA::WebAPI');
$t->get_ok('/')->status_is(200)->content_like(qr/Welcome to openQA/i);
