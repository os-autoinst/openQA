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

OpenQA::Test::Case->new(config_directory => "$FindBin::Bin/../data/17-mcp")
  ->init_data(fixtures_glob => '01-jobs.pl 03-users.pl');

my $PERSONAL_ACCESS_TOKEN = 'lance:LANCELOTKEY01:MANYPEOPLEKNOW';

my $t = Test::Mojo->new('OpenQA::WebAPI');
my $client = MCP::Client->new(ua => $t->ua, url => $t->ua->server->url->path('/experimental/mcp'));

subtest 'Authentication' => sub {
    $t->get_ok('/experimental/mcp')->status_is(403)->json_is({error => 'no api key'});

    $t->ua->on(start => sub ($ua, $tx) { $tx->req->url->userinfo($PERSONAL_ACCESS_TOKEN) });
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
    is scalar @{$result->{tools}}, 2, 'two tools available';
    is $result->{tools}[0]{name}, 'openqa_user', 'right tool name';
    is $result->{tools}[1]{name}, 'openqa_job_info', 'right tool name';
};

subtest 'openqa_user tool' => sub {
    my $result = $client->call_tool('openqa_user');
    ok !$result->{isError}, 'not an error';
    my $text = $result->{content}[0]{text};
    like $text, qr/name: lance, id: 99902, admin: no, operator: no/, 'right content';
};

subtest 'openqa_job_info tool' => sub {
    subtest 'Failed job' => sub {
        my $result = $client->call_tool('openqa_job_info', {job_id => 99938});
        ok !$result->{isError}, 'not an error';
        my $text = $result->{content}[0]{text};
        like $text, qr/Job ID: +99938/, 'has job id';
        like $text, qr/Name: +opensuse-Factory-DVD-x86_64-Build0048-doc\@64bit/, 'has name';
        like $text, qr/Group: +opensuse/, 'has group';
        like $text, qr/Priority: +36/, 'has priority';
        like $text, qr/State: +done/, 'has state';
        like $text, qr/Result: +failed/, 'has result';
        like $text, qr/Started: +\d+-\d+-\d+T\d+:\d+:\d+/, 'has started time';
        like $text, qr/Finished: +\d+-\d+-\d+T\d+:\d+:\d+/, 'has finished time';
        like $text, qr/No test results available yet/s, 'no test results yet';
        like $text, qr/DISTRI: opensuse/, 'settings are present';
        like $text, qr/VERSION: Factory/, 'settings are present';
        like $text, qr/No comments yet/, 'no comments yet';
    };
};

done_testing();
