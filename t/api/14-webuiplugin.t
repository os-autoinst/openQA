# Copyright (C) 2019 SUSE LLC
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
    unshift @INC, 'lib';
}

use Mojo::Base -strict;
use Mojo::File qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Test::Mojo;
use OpenQA::Test::Database;
use Test::Warnings 0.005 ':all';

my $tempdir = tempdir;
$ENV{OPENQA_CONFIG} = $tempdir;

# we must create db, otherwise OpenQA::WebAPI will try to
my $db = OpenQA::Test::Database->new->create(skip_fixtures => 1);

sub check_plugin {
    my ($config, $expected_status) = @_;

    $tempdir->child("openqa.ini")->spurt($config);
    my $t = eval { Test::Mojo->new('OpenQA::WebAPI'); };

    if (!defined $t) {
        ok(!defined $expected_status, "WebAPI startup");
    }
    else {
        my $app = $t->app;
        $t->ua(OpenQA::Client->new()->ioloop(Mojo::IOLoop->singleton));
        $t->app($app);
        $t->ua->apikey('PERCIVALKEY01');
        $t->ua->apisecret('PERCIVALSECRET01');
        ok($t->get_ok('/plugin/hello')->status_is($expected_status), "API");
        ok($t->get_ok('/plugin/Hello')->status_is($expected_status), "API form");
    }
}

sub config_string {
    my ($enabled, $path) = @_;
    return "[PluginWebAPIHello]\nenabled = $enabled\npath = $path";
}

my $correct_path   = "t/data/OpenQA/Plugin/WebAPI";
my $incorrect_path = "t/data/OpenQA/";

# first test failures, because outcome may change once plugin was loaded by perl
check_plugin("", 404);
# pass undef to $xpected_status means that application startup is expected to fail
check_plugin(config_string("required", $incorrect_path), undef);
# here we expect warning about plugin failed to load
like(
    warning { check_plugin(config_string("optional", $incorrect_path), 404) },
    qr/Failed to load.*/,
    "Warn Plugin load"
);

check_plugin(config_string("optional", $correct_path), 200);
check_plugin(config_string("required", $correct_path), 200);

done_testing();
