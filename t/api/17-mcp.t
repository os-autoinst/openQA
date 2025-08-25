#!/usr/bin/env perl

# Copyright 2025 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Mojo::Base -signatures;
use Test::Mojo;
use Test::Warnings ':report_warnings';
use Test::MockModule;
use OpenQA::Test::TimeLimit '30';
use OpenQA::Test::Case;
use OpenQA::Test::Client 'client';
use MCP::Client;

OpenQA::Test::Case->new->init_data(fixtures_glob => '03-users.pl');

# Bearer token authentication
my $bearer_token = 'Bearer lance:LANCELOTKEY01:MANYPEOPLEKNOW';

my $t = Test::Mojo->new('OpenQA::WebAPI');
my $client = MCP::Client->new(ua => $t->ua, url => $t->ua->server->url->path('/experimental/mcp'));

subtest 'Authentication' => sub {
    $t->get_ok('/experimental/mcp')->status_is(403)->json_is({error => 'no api key'});

    $t->ua->on(start => sub ($ua, $tx) { $tx->req->headers->authorization($bearer_token) });
    $t->get_ok('/experimental/mcp')->status_is(405);
};

subtest 'Start session' => sub {
    is $client->session_id, undef, 'no session id';
    my $result = $client->initialize_session;
    is $result->{serverInfo}{name}, 'openQA', 'server name';
    is $result->{serverInfo}{version}, '1.0.0', 'server version';
    ok $result->{capabilities}, 'has capabilities';
    ok $client->session_id, 'session id set';
};

subtest 'List tools' => sub {
    my $result = $client->list_tools;
    is scalar @{$result->{tools}}, 1, 'one tool available';
    is $result->{tools}[0]{name}, 'current_user', 'right tool name';
};

subtest 'Current user tool' => sub {
    my $result = $client->call_tool('current_user');
    is_deeply $result->{content}, [{type => 'text', text => 'name: lance, id: 99902'}], 'right content';
    ok !$result->{isError}, 'not an error';
};

done_testing();
