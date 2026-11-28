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
    $t->app->config->{global}{mcp_enabled} = 'read-only';
    my $mcp_help = 'MCP help ';
    $t->get_ok('/tests')->status_is(200);
    my $actions = OpenQA::Test::Case::trim_whitespace($t->tx->res->dom->at('#user-action')->all_text);
    like $actions, qr/API help ${mcp_help}Changelog Logout/, 'MCP entry is shown for operator when MCP is enabled';
};

subtest 'MCP write mode enabled' => sub {
    $t->app->config->{global}{mcp_enabled} = 'read-write';
    my $mcp_help = 'MCP help ';
    $t->get_ok('/tests')->status_is(200);
    my $actions = OpenQA::Test::Case::trim_whitespace($t->tx->res->dom->at('#user-action')->all_text);
    like $actions, qr/API help ${mcp_help}Changelog Logout/, 'MCP entry is shown for operator in write mode';
};

subtest 'MCP help page' => sub {
    $t->app->config->{global}{mcp_enabled} = 'read-write';
    $t->get_ok('/mcp_help')->status_is(200);
    my $text = OpenQA::Test::Case::trim_whitespace($t->tx->res->dom->all_text);
    like $text, qr/read-write/, 'mode shown';
    like $text, qr/openqa_trigger_job/, 'write tool listed in write mode';
    like $text, qr/opencode/, 'client configuration example shown';
    $t->app->config->{global}{mcp_enabled} = 'read-only';
    $t->get_ok('/mcp_help')->status_is(200);
    $text = OpenQA::Test::Case::trim_whitespace($t->tx->res->dom->all_text);
    like $text, qr/openqa_list_jobs/, 'read tool listed';
    unlike $text, qr/openqa_trigger_job/, 'write tool not listed in read-only mode';
};

done_testing();
