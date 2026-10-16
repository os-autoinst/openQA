# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Mojo::Base -signatures;
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '30';
use OpenQA::Test::Case;
use MCP::Client;
use Mojo::JSON 'true';

OpenQA::Test::Case->new(config_directory => "$FindBin::Bin/../data/18-mcp")
  ->init_data(fixtures_glob => '01-jobs.pl 02-workers.pl 03-users.pl');

my $OPERATOR_TOKEN = 'perci:PERCIVALKEY02:PERCIVALSECRET02';
my $ADMIN_TOKEN = 'artie:ARTHURKEY01:EXCALIBUR';
my $USER_TOKEN = 'lance:LANCELOTKEY01:MANYPEOPLEKNOW';
my @WRITE_TOOLS
  = qw(openqa_cancel_job openqa_duplicate_job openqa_restart_job openqa_set_job_priority openqa_trigger_job);
my %write_tools = map { $_ => 1 } @WRITE_TOOLS;

my $t = Test::Mojo->new('OpenQA::WebAPI');
my $client = MCP::Client->new(ua => $t->ua, url => $t->ua->server->url->path('/mcp'));
my $jobs = $t->app->schema->resultset('Jobs');

sub auth ($token) {
    $t->ua->on(start => sub ($ua, $tx) { $tx->req->headers->authorization("Bearer $token") });
}

sub tool_names () {
    [sort map { $_->{name} } @{$client->list_tools->{tools}}]
}
sub audit ($event) { $t->app->schema->resultset('AuditEvents')->search({event => $event})->count }

subtest 'Write tools listed for operator only' => sub {
    auth($USER_TOKEN);
    is_deeply [grep { $write_tools{$_} } @{tool_names()}], [],
      'no write tools listed for a user without operator rights';
    auth($OPERATOR_TOKEN);
    is_deeply [grep { $write_tools{$_} } @{tool_names()}], [sort @WRITE_TOOLS], 'job write tools listed for operator';
};


subtest 'openqa_set_job_priority tool' => sub {
    my $result = $client->call_tool('openqa_set_job_priority', {job_id => 99938, prio => 7});
    ok !$result->{isError}, 'not an error';
    is $jobs->find(99938)->priority, 7, 'priority changed in the database';
};

subtest 'openqa_trigger_job tool' => sub {
    my $result = $client->call_tool('openqa_trigger_job', {settings => {TEST => 'mcp-test', DISTRI => 'opensuse'}});
    ok !$result->{isError}, 'not an error';
    my $id = $result->{structuredContent}{id};
    ok $id, 'new job id reported';
    is $jobs->find($id)->TEST, 'mcp-test', 'job created with the requested settings';
    is audit('job_create'), 1, 'job creation recorded in the audit log';
};

subtest 'openqa_restart_job tool' => sub {
    my $result
      = $client->call_tool('openqa_restart_job', {job_id => 99938, settings => {BUILD => '0043'}, force => true});
    ok !$result->{isError}, 'not an error';
    my $clone = $result->{structuredContent}{result}[0]{99938};
    ok $clone, 'clone created';
    is $jobs->find($clone)->BUILD, '0043', 'setting overridden on the clone';
};

subtest 'openqa_duplicate_job tool' => sub {
    my $result = $client->call_tool('openqa_duplicate_job', {job_id => 99936});
    ok !$result->{isError}, 'not an error';
    my $clone = $result->{structuredContent}{id};
    ok $clone, 'duplicate id reported for the duplicated job';
    is $jobs->find($clone)->group_id, 1001, 'duplicate is in the job group of the original job';
};

subtest 'openqa_cancel_job tool' => sub {
    my $result = $client->call_tool('openqa_cancel_job', {job_id => 99928, reason => 'not needed anymore'});
    ok !$result->{isError}, 'not an error';
    is $jobs->find(99928)->state, 'cancelled', 'scheduled job cancelled';
    is audit('job_cancel'), 1, 'cancellation recorded in the audit log';
};

subtest 'Missing job is reported' => sub {
    my $result = $client->call_tool('openqa_set_job_priority', {job_id => 999_999_999, prio => 1});
    ok $result->{isError}, 'is an error';
    like $result->{content}[0]{text}, qr/Job does not exist/, 'controller error message forwarded';
};

subtest 'openqa_post_comment tool' => sub {
    my $result = $client->call_tool('openqa_post_comment', {job_id => 99764, text => 'triage: known flake'});
    ok !$result->{isError}, 'not an error';
    ok $result->{structuredContent}{id}, 'comment id reported';
    is audit('comment_create'), 1, 'comment recorded in the audit log';
};

subtest 'openqa_schedule_iso tool' => sub {
    my $result = $client->call_tool(
        'openqa_schedule_iso',
        {
            settings => {
                DISTRI => 'opensuse',
                VERSION => 'Factory',
                FLAVOR => 'DVD',
                ARCH => 'x86_64',
                BUILD => '0042',
                ISO => 'Factory-DVD-x86_64-Build0042.iso',
                REPO => 'http://download.opensuse.org'
            }});
    ok !$result->{isError}, 'not an error';
    ok $result->{structuredContent}{scheduled_product_id}, 'scheduled product created';
    is audit('iso_create'), 1, 'scheduling recorded in the audit log';
};

subtest 'ISO scheduling requires operator' => sub {
    auth($USER_TOKEN);
    dies_ok { $client->call_tool('openqa_schedule_iso', {settings => {DISTRI => 'opensuse'}}) }
    'call refused for a user without operator rights';
};

subtest 'Admin role required for admin tools' => sub {
    auth($OPERATOR_TOKEN);
    my $result = $client->call_tool('openqa_set_job_priority', {job_id => 99938, prio => 3});
    ok !$result->{isError}, 'operator allowed for operator role';
    auth($ADMIN_TOKEN);
    $result = $client->call_tool('openqa_set_job_priority', {job_id => 99938, prio => 4});
    ok !$result->{isError}, 'admin allowed for operator role';
};

done_testing();
