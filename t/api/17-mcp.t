#!/usr/bin/env perl

# Copyright SUSE LLC
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
  ->init_data(fixtures_glob => '01-jobs.pl 02-workers.pl 03-users.pl');

my $PERSONAL_ACCESS_TOKEN = 'lance:LANCELOTKEY01:MANYPEOPLEKNOW';

my $t = Test::Mojo->new('OpenQA::WebAPI');
my $client = MCP::Client->new(ua => $t->ua, url => $t->ua->server->url->path('/experimental/mcp'));

subtest 'Authentication' => sub {
    $t->get_ok('/experimental/mcp')->status_is(403)->json_is({error => 'no api key'});

    $t->ua->on(start => sub ($ua, $tx) { $tx->req->headers->authorization("Bearer $PERSONAL_ACCESS_TOKEN") });
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
    is scalar @{$result->{tools}}, 3, 'three tools available';
    is $result->{tools}[0]{name}, 'openqa_get_info', 'right tool name';
    is $result->{tools}[1]{name}, 'openqa_get_job_info', 'right tool name';
    is $result->{tools}[2]{name}, 'openqa_get_log_file', 'right tool name';
};

subtest 'openqa_get_info tool' => sub {
    my $result = $client->call_tool('openqa_get_info');
    ok !$result->{isError}, 'not an error';
    my $text = $result->{content}[0]{text};
    like $text, qr/Server: openQA \(.+\)/, 'openQA server';
    like $text, qr/Current User: lance \(id: 99902, admin: no, operator: no\)/, 'current user';
    like $text, qr/Workers: 2/, 'total workers';
    like $text, qr/- online: 0/, 'online workers';
    like $text, qr/- offline: 2/, 'offline workers';
    like $text, qr/- idle: 0/, 'idle workers';
    like $text, qr/- busy: 0/, 'busy workers';
    like $text, qr/- broken: 0/, 'broken workers';
};

subtest 'openqa_get_job_info tool' => sub {
    subtest 'Failed job' => sub {
        my $result = $client->call_tool('openqa_get_job_info', {job_id => 99938});
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
        like $text, qr/- autoinst-log\.txt/s, 'has log files listed';
        like $text, qr/No test results available yet/s, 'no test results yet';
        like $text, qr/DISTRI: opensuse/, 'settings are present';
        like $text, qr/VERSION: Factory/, 'settings are present';
        like $text, qr/No comments yet/, 'no comments yet';
    };

    subtest 'Passed job' => sub {
        subtest 'Add comment to test job' => sub {
            $t->post_ok("/api/v1/jobs/99764/comments" => form => {text => 'Just a test comment'})->status_is(200);
        };

        my $result = $client->call_tool('openqa_get_job_info', {job_id => 99764});
        ok !$result->{isError}, 'not an error';
        my $text = $result->{content}[0]{text};
        like $text, qr/Job ID: +99764/, 'has job id';
        like $text, qr/Name: +opensuse-13.1-DVD-x86_64-Build0091-console_tests\@64bit/, 'has name';
        like $text, qr/Group: +Unknown/, 'unknown group';
        like $text, qr/Priority: +35/, 'has priority';
        like $text, qr/State: +done/, 'has state';
        like $text, qr/Result: +passed/, 'has result';
        like $text, qr/Started: +\d+-\d+-\d+T\d+:\d+:\d+/, 'has started time';
        like $text, qr/Finished: +\d+-\d+-\d+T\d+:\d+:\d+/, 'has finished time';
        like $text, qr/No logs available/s, 'no log files listed';
        like $text, qr/No test results available yet/s, 'no test results yet';
        like $text, qr/DISTRI: opensuse/, 'settings are present';
        like $text, qr/VERSION: 13\.1/, 'settings are present';
        like $text, qr/lance.+Just a test comment/, 'has comments';
    };

    subtest 'Input validation failed' => sub {
        eval { $client->call_tool('openqa_get_job_info', {job_id => 'abc'}) };
        like $@, qr/Error -32602: Invalid arguments/, 'right error message';
    };
};

subtest 'openqa_get_log_file tool' => sub {
    subtest 'Failed job' => sub {
        my $result = $client->call_tool('openqa_get_log_file', {job_id => 99938, file_name => 'autoinst-log.txt'});
        ok !$result->{isError}, 'not an error';
        my $text = $result->{content}[0]{text};
        like $text, qr/starting: \/usr\/bin\/qemu-kvm/, 'has log content from start';
        like $text, qr/test logpackages died/, 'has log content from end';
    };

    subtest 'Input validation failed' => sub {
        eval { $client->call_tool('openqa_get_log_file', {job_id => 'abc', file_name => 'autoinst-log.txt'}) };
        like $@, qr/Error -32602: Invalid arguments/, 'right error message';
        eval { $client->call_tool('openqa_get_log_file', {job_id => 99938, file_name => ''}) };
        like $@, qr/Error -32602: Invalid arguments/, 'right error message';
    };

    subtest 'Path traversal attack' => sub {
        my $result = $client->call_tool('openqa_get_log_file', {job_id => 99938, file_name => '../../etc/passwd'});
        ok $result->{isError}, 'is an error';
        my $text = $result->{content}[0]{text};
        like $text, qr/Invalid file name/, 'error message';
    };

    subtest 'Job does not exist' => sub {
        local $t->app->config->{misc_limits}{mcp_max_result_size} = 100;
        my $result = $client->call_tool('openqa_get_log_file', {job_id => 999999999, file_name => 'autoinst-log.txt'});
        ok $result->{isError}, 'is an error';
        my $text = $result->{content}[0]{text};
        like $text, qr/Job does not exist/, 'error message';
    };

    subtest 'Unsupported file type' => sub {
        my $result = $client->call_tool('openqa_get_log_file', {job_id => 99938, file_name => 'video.ogv'});
        ok $result->{isError}, 'is an error';
        my $text = $result->{content}[0]{text};
        like $text, qr/File type not yet supported via MCP/, 'error message';
    };

    subtest 'File too large' => sub {
        local $t->app->config->{misc_limits}{mcp_max_result_size} = 100;
        my $result = $client->call_tool('openqa_get_log_file', {job_id => 99938, file_name => 'autoinst-log.txt'});
        ok $result->{isError}, 'is an error';
        my $text = $result->{content}[0]{text};
        like $text, qr/File too large to be transmitted via MCP/, 'error message';
    };
};

done_testing();
