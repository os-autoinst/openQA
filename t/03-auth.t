# Copyright (C) 2020 SUSE LLC
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
# with this program; if not, see <http://www.gnu.org/licenses/>.

use Mojo::Base -strict;

use FindBin;
use lib "$FindBin::Bin/lib";
use Test::MockModule;
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Database;
use Mojo::File qw(tempdir path);

my $t;
my $tempdir = tempdir;

sub test_auth_method_startup {
    my $auth = shift;
    my @conf = ("[auth]\n", "method = \t  $auth \t\n");
    $ENV{OPENQA_CONFIG} = $tempdir;
    $tempdir->child("openqa.ini")->spurt(@conf);

    $t = Test::Mojo->new('OpenQA::WebAPI');
    ok($t->app->config->{auth}->{method} eq $auth, "started successfully with auth $auth");
    $t->get_ok('/login');
}

OpenQA::Test::Database->new->create(skip_fixtures => 1);

test_auth_method_startup('Fake')->status_is(302);
# openid relies on external server which we mock to not rely on external
# dependencies
my $openid_mock = Test::MockModule->new('Net::OpenID::Consumer');
$openid_mock->redefine(claimed_identity => undef);
test_auth_method_startup('OpenID')->status_is(403);

eval { test_auth_method_startup('nonexistant') };
ok($@, 'refused to start with non existant auth module');

done_testing;
