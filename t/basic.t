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

BEGIN { unshift @INC, 'lib'; }

use Mojo::Base -strict;

use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Database;

OpenQA::Test::Database->new->create(skip_fixtures => 1);

my $t = Test::Mojo->new('OpenQA::WebAPI');
$t->get_ok('/')->status_is(200)->content_like(qr/Welcome to openQA/i);

sub test_auth_method_startup {
    my $auth = shift;

    $ENV{OPENQA_CONFIG} = 't';
    open(my $fd, '>', $ENV{OPENQA_CONFIG} . '/openqa.ini');
    print $fd "[auth]\n";
    print $fd "method = \t  $auth \t\n";
    close $fd;

    no warnings 'redefine';
    my $t = Test::Mojo->new('OpenQA::WebAPI');
    ok($t->app->config->{auth}->{method} eq $auth, "started successfully with auth $auth");
    unlink($ENV{OPENQA_CONFIG} . '/openqa.ini');
}

OpenQA::Test::Database->new->create(skip_fixtures => 1);

for my $a (qw(Fake OpenID iChain)) {
    test_auth_method_startup($a);
}

eval { test_auth_method_startup('nonexistant') };
ok($@, 'refused to start with non existant auth module');


done_testing();
