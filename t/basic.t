# Copyright (C) 2014-2017 SUSE LLC
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
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Database;
use Mojo::File qw(tempdir path);

OpenQA::Test::Database->new->create(skip_fixtures => 1);

my $t = Test::Mojo->new('OpenQA::WebAPI');
$t->get_ok('/')->status_is(200)->content_like(qr/Welcome to openQA/i);

my $tempdir = tempdir;

sub test_auth_method_startup {
    my $auth = shift;

    my @conf = ("[auth]\n", "method = \t  $auth \t\n");
    $ENV{OPENQA_CONFIG} = $tempdir;
    $tempdir->child("openqa.ini")->spurt(@conf);

    no warnings 'redefine';
    my $t = Test::Mojo->new('OpenQA::WebAPI');
    ok($t->app->config->{auth}->{method} eq $auth, "started successfully with auth $auth");
}

OpenQA::Test::Database->new->create(skip_fixtures => 1);

for my $auth (qw(Fake OpenID)) {
    test_auth_method_startup($auth);
}

eval { test_auth_method_startup('nonexistant') };
ok($@, 'refused to start with non existant auth module');


done_testing();
