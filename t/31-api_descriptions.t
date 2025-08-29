# Copyright 2017-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::MockModule;
use Test::Warnings ':report_warnings';
# no OpenQA::Test::TimeLimit for this trivial test

use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Mojo::File qw(path);

use Mojo::Base 'Mojolicious', -signatures;

use_ok('OpenQA::WebAPI::Description', qw(get_pod_from_controllers set_api_desc));
my $app = Mojolicious->new;
get_pod_from_controllers($app);

# mock the parse_file
my $mock = Test::MockModule->new('Pod::POM');
$mock->redefine('parse_file', sub { return });

# create fake controller main
# TODO: do a refactor :)
my $API_path = '/lib/OpenQA/WebAPI/Controller/API/V1/';
my $tmp_controller_path = tempdir(CLEANUP => 0);
make_path(path($tmp_controller_path, $API_path));
my $tmp_controller_file = path($tmp_controller_path)->child('Main.pm');
my $new_file = "$tmp_controller_path/$API_path/Main.pm";
open my $fh, '>', $new_file or die "open($new_file): $!";
close $fh;

# update home of mojo app
$app->home($tmp_controller_path);

# create route
my $route_child = $app->routes->any('/child')->to(controller => 'Main');
my $route = $app->routes->any('/*wathever')->add_child($route_child);

get_pod_from_controllers($app, $route);

done_testing;
