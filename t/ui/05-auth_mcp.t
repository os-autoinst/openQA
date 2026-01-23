# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use Test::Mojo;
use Test::Warnings ':report_warnings';
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '8';
use OpenQA::Test::Case;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data(fixtures_glob => '03-users.pl');

my $t = Test::Mojo->new('OpenQA::WebAPI');

subtest 'First access no login' => sub {
    $t->get_ok('/tests')->status_is(200);
    my $actions = OpenQA::Test::Case::trim_whitespace($t->tx->res->dom->at('#user-action')->all_text);
    is $actions, 'Login', 'no-one logged in';
};

subtest 'MCP disabled' => sub {
    $test_case->login($t, 'percival');
    $t->app->config->{global}{mcp_enabled} = 'no';
    my $mcp_help = '';
    $t->get_ok('/tests')->status_is(200);
    my $actions = OpenQA::Test::Case::trim_whitespace($t->tx->res->dom->at('#user-action')->all_text);
    like $actions, qr/API help ${mcp_help}Changelog Logout/, 'no MCP entry shown for operator when MCP not enabled';
};

subtest 'MCP enabled' => sub {
    $t->app->config->{global}{mcp_enabled} = 'read_only';
    my $mcp_help = 'MCP help ';
    $t->get_ok('/tests')->status_is(200);
    my $actions = OpenQA::Test::Case::trim_whitespace($t->tx->res->dom->at('#user-action')->all_text);
    like $actions, qr/API help ${mcp_help}Changelog Logout/, 'MCP entry is shown for operator when MCP is enabled';
};

done_testing();
