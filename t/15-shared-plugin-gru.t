#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use Test::Warnings ':report_warnings';
use Test::MockModule;
use Test::MockObject;
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '5';
use OpenQA::App;
use OpenQA::Shared::Plugin::Gru;    # SUT

ok my $gru = OpenQA::Shared::Plugin::Gru->new, 'can instantiate gru plugin';

my $connect_info = {dsn => 'my_dsn', user => 'user', password => 'foo'};
my $storage = Test::MockObject->new->set_always(connect_info => [$connect_info]);
my $schema = Test::MockObject->new->set_always(storage => $storage)->set_true('search_path_for_tests');
my %config = (misc_limits => {minion_job_max_age => 0});
my $minion = Test::MockObject->new->set_true('on');
my $log = Test::MockObject->new->set_true('level', 'info');
my $under = Test::MockObject->new->set_true('to');
my $routes = Test::MockObject->new->set_always(under => $under);
my $app
  = Test::MockObject->new->set_always(schema => $schema)
  ->set_always(config => \%config)
  ->set_always(minion => $minion)
  ->set_always(log => $log)
  ->set_always(routes => $routes)
  ->set_true('plugin', 'helper');
OpenQA::App->set_singleton($app);
my $mock = Test::MockModule->new('OpenQA::Shared::Plugin::Gru');
$mock->noop('_allow_unauthenticated_minion_stats');
my $pg = Test::MockObject->new->set_true('dsn', 'username', 'password', 'search_path', 'find');
my $pg_module = Test::MockModule->new('Mojo::Pg')->redefine(new => $pg);
ok $gru->register($app, undef), 'can register gru plugin';
$pg->called_ok('username', 'pg connection initialized with username');
is(($pg->call_args(0))[1], $connect_info->{user}, 'pg connection username is correct');
is(($pg->call_args(2))[1], $connect_info->{password}, 'pg connection password is correct');
is(($app->call_args(4))[1], 'Minion', 'minion initialized');
is(($app->call_args(4))[2]->{Pg}, $pg, 'pg connection initialized on minion');

done_testing;
