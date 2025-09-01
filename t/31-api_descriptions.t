# Copyright 2017-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::MockModule;
use Test::Warnings ':report_warnings';
use Test::Output qw(combined_like);
# no OpenQA::Test::TimeLimit for this trivial test

use File::Temp qw(tempdir);
use Mojo::File qw(path);

use Mojo::Base 'Mojolicious', -signatures;

use_ok('OpenQA::WebAPI::Description', qw(get_pod_from_controllers set_api_desc));
my $app = Mojolicious->new;
get_pod_from_controllers($app);

my $mock = Test::MockModule->new('Pod::POM');
my $app_home = tempdir();
my $route = $app->routes->any('/*wathever')->add_child($app->routes->any('/child')->to(controller => 'Main'));

$mock->redefine(parse_file => undef);
path($app_home . '/lib/OpenQA/WebAPI/Controller/API/V1/')->make_path->child('Main.pm')->touch;
$app->home($app_home);

combined_like {
    get_pod_from_controllers($app, $route)
}
qr/\[WARN\].*get_pod_from_controllers/, 'Warning when file does not exist';

done_testing;
