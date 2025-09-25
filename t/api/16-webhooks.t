#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -base, -signatures;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings;
use Test::MockModule;
use Digest::SHA qw(hmac_sha256_hex);
use OpenQA::App;
use OpenQA::Schema::Result::ScheduledProducts;
use OpenQA::Test::TimeLimit '5';
use OpenQA::Test::Case;
use OpenQA::Test::Utils qw(perform_minion_jobs);
use OpenQA::Jobs::Constants;
use Mojo::File qw(path);
use Mojo::JSON qw(encode_json decode_json);
use Mojo::Transaction::HTTP;

my $case = OpenQA::Test::Case->new->init_data(fixtures_glob => '03-users.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');
my $app = OpenQA::App->singleton;
my $minion = $app->minion;
my $scheduled_products = $app->schema->resultset('ScheduledProducts');
my $jobs = $app->schema->resultset('Jobs');
my $ioloop = Mojo::IOLoop->singleton;
my $url_base = '/api/v1/webhooks/product';
my $url = "$url_base/?DISTRI=opensuse&VERSION=13.1&FLAVOR=DVD&ARCH=i586&BUILD=0091&TEST=autoyast_btrfs";
my $test_payload = decode_json(path("$FindBin::Bin/../data/example-webhook-payload.json")->slurp);
my $ua = $app->ua->ioloop($ioloop);
my %headers = ('X-GitHub-Event' => 'pull_request');
my $validation_mock = Test::MockModule->new('OpenQA::WebAPI::Controller::API::V1::Webhook');
$app->config->{'scm git'}->{git_auto_clone} = 'no';

subtest 'signature validation' => sub {
    my $payload = 'some text';
    my $tx = Mojo::Transaction::HTTP->new;
    my $c = OpenQA::WebAPI::Controller::API::V1::Webhook->new(tx => $tx);
    ok !$c->validate_signature, 'failure without signature';
    $c->tx->req->headers->header('X-Hub-Signature-256', 'sha256=' . hmac_sha256_hex($payload, 'foobar'));
    ok !$c->validate_signature, 'failure without secret';
    $c->stash(webhook_validation_secret => 'foobar');
    ok !$c->validate_signature, 'failure without matching payload';
    $c->tx->req->body($payload);
    ok $c->validate_signature, 'success';
};

subtest 'error cases' => sub {
    $t->ua(OpenQA::Client->new(apikey => 'LANCELOTKEY01', apisecret => 'MANYPEOPLEKNOW')->ioloop($ioloop))->app($app);
    $t->post_ok($url_base)->status_is(403, 'posting webhook not allowed by any user');

    $t->ua(OpenQA::Client->new(apikey => 'PERCIVALKEY01', apisecret => 'PERCIVALSECRET01')->ioloop($ioloop))->app($app);
    $t->post_ok($url_base)->status_is(404, 'posting webhook not possible if GitHub token missing');
    $t->content_like(qr/not available.+no.+token/, 'error message about missing token missing');

    $app->config->{secrets}->{github_token} = 'the-token';
    $t->post_ok($url_base)->status_is(403, 'posting webhook signature validation fails');
    $t->content_is('invalid signature', 'error message about invalid signature');

    $validation_mock->redefine(validate_signature => 1);
    $t->post_ok($url_base);
    $t->status_is(404, 'posting webhook not possible if GitHub event is missing/unsupported');
    $t->content_like(qr/specified event cannot be handled/, 'error message about missing unsupported event');

    $t->post_ok($url_base, {'X-GitHub-Event' => 'ping'})->status_is(200, 'ping -> pong');
    $t->content_is('pong', 'got pong response for ping');

    $t->post_ok($url_base, \%headers)->status_is(400, 'error if mandatory parameters missing');
    $t->content_like(qr/missing parameters/, 'error message about missing mandatory parameters');

    $t->post_ok($url, \%headers)->status_is(400, 'error if JSON payload missing');
    $t->content_like(qr/payload missing/, 'error message about missing payload');

    $t->post_ok($url, \%headers, json => {action => 'foo'})->status_is(404, 'error if action cannot be handled');
    $t->content_like(qr/action cannot be handled/, 'error message about unsupported action');

    $t->post_ok($url, \%headers, json => {action => 'opened'})->status_is(400, 'error if required fields are missing');
    $t->content_like(qr/missing fields: .+/, 'error message about missing required fields');
};

subtest 'failure when reporting status to GitHub' => sub {
    $t->post_ok($url, \%headers, json => $test_payload)
      ->status_is(500, 'error returned when GitHub status cannot be created');
    is $minion->jobs->total, 0, 'no Minion job created';
    is $scheduled_products->count, 0, 'no scheduled product created';
};

# mock reporting back to GitHub
my $vcs_mock = Test::MockModule->new('OpenQA::VcsProvider');
my $minion_job_id;
my $status_reports = 0;
my $expected_sha = '04a3f669ea13a4aa7cbd4569f578a66f7403c43d';
my $expected_path = "Martchus/openQA/$expected_sha/scenario-definitions.yaml";
my $expected_url = "https://raw.githubusercontent.com/$expected_path";
my $expected_statuses_url = "https://127.0.0.1/repos/os-autoinst/openQA/statuses/$expected_sha";
my $expected_ci_check_state = 'pending';
my $expected_ci_check_desc = undef;
$vcs_mock->redefine(
    report_status_to_git =>
      sub ($self, $params, $scheduled_product_id, $base_url_from_req, $callback) {
        my $tx = $ua->build_tx(POST => 'http://dummy');
        is $self->statuses_url, $expected_statuses_url, 'URL from webhook payload used for reporting back';
        is $params->{state}, $expected_ci_check_state, "check reported to be $expected_ci_check_state";
        is $params->{description}, $expected_ci_check_desc, 'check description';
        ++$status_reports;
        $callback ? $callback->($ua, $tx) : $tx;
      });

subtest 'scheduled product created via webhook' => sub {
    $t->post_ok($url, \%headers, json => $test_payload)->status_is(200, 'scheduled product has been created');
    $t->json_is('/scheduled_product_id', 2, 'scheduled product ID returned');
    is $minion->jobs->total, 1, 'created one Minion job';
    is $scheduled_products->count, 1, 'created one scheduled product';
    is $status_reports, 1, 'exactly one status report to GitHub happened';
    my $scheduled_product = $scheduled_products->first;
    my $scheduled_product_settings = $scheduled_product->settings;
    is $scheduled_product->webhook_id, 'gh:pr:1234', 'webhook ID assigned';
    ok delete $scheduled_product_settings->{CI_TARGET_URL}, 'CI_TARGET_URL assigned';
    is_deeply $scheduled_product_settings,
      {
        TEST => 'autoyast_btrfs',
        ARCH => 'i586',
        BUILD => '0091',
        DISTRI => 'opensuse',
        VERSION => '13.1',
        FLAVOR => 'DVD',
        CASEDIR => "https://github.com/Martchus/openQA.git#$expected_sha",
        NEEDLES_DIR => '%%CASEDIR%%/needles',
        PRIO => '100',
        _GROUP_ID => '0',
        GITHUB_PR_URL => 'https://github.com/os-autoinst/openQA/pull/5111',
        GITHUB_REPO => 'Martchus/openQA',
        GITHUB_SHA => $expected_sha,
        GITHUB_STATUSES_URL => $expected_statuses_url,
        SCENARIO_DEFINITIONS_YAML_FILE => $expected_url,
      },
      'expected settings assigned'
      or always_explain $scheduled_product_settings;
} or BAIL_OUT 'unable to created scheduled product';

subtest 'triggering the scheduled product will download scenario definitions YAML file from GitHub' => sub {
    $expected_ci_check_state = 'failure';
    $expected_ci_check_desc = 'No openQA jobs have been scheduled';
    perform_minion_jobs $minion;
    my $expected_error = qr/Unable to download SCENARIO_DEFINITIONS_YAML_FILE from '$expected_url': .+/;
    ok my $scheduled_product = $scheduled_products->find(2), 'scheduled product still there' or return;
    is $scheduled_product->status, SCHEDULED, 'scheduled product considered scheduled';
    like $scheduled_product->results->{error}, $expected_error, 'download error stored as result';
    my $minion_job = $minion->jobs->next;
    is $minion_job->{state}, 'finished', 'Minion job finished (not failed, we do not want alerts for these errors)';
    like $minion_job->{result}->{error}, $expected_error, 'error assigned as Minion job result'
      or always_explain $minion_job;
    is $status_reports, 2, 'the status has been reported back to GitHub';
    $minion_job_id = $minion_job->{id};
    is $jobs->count, 0, 'no jobs have been created yet';
};

# mock download of SCENARIO_DEFINITIONS_YAML_FILE
my $ua_mock = Test::MockModule->new('Mojo::UserAgent');
my $yaml = path("$FindBin::Bin/../data/09-schedule_from_file.yaml")->slurp;
$ua_mock->redefine(
    get => sub ($self, $url) {
        my $tx = $ua->build_tx(POST => 'http://dummy');
        $tx->res->body($yaml);
        is $url, $expected_url, 'expected URL used to download SCENARIO_DEFINITIONS_YAML_FILE';
        return $tx;
    });

subtest 'triggering the scheduled product will report status back to GitHub' => sub {
    # set back scheduled product and retry Minion job
    $expected_ci_check_state = 'pending';
    $expected_ci_check_desc = 'All 2 openQA jobs are pending';
    $scheduled_products->find(2)->update({status => ADDED});
    $minion->job($minion_job_id)->retry;
    perform_minion_jobs $minion;

    # check Minion job's result; we should have 2 jobs now (same scenarios/parameters as in `02-iso-yaml.t`)
    my $minion_job = $minion->jobs->next;
    my %expected_res = (failed_job_info => [], successful_job_ids => [1, 2]);
    is $minion_job->{state}, 'finished', 'Minion job finished';
    is_deeply $minion_job->{result}, \%expected_res, 'expected result' or always_explain $minion_job;

    # set the jobs to done; this should lead to reporting back to GitHub
    $expected_ci_check_state = 'pending';
    $expected_ci_check_desc = '1 of 2 openQA jobs is pending';
    my @jobs = $jobs->search({}, {order_by => 'id'});
    is @jobs, 2, 'two jobs have been cloned';
    $jobs[0]->done(result => PASSED);
    is $status_reports, 4, 'the intermediate status has been reported back to GitHub';
    $expected_ci_check_state = 'success';
    $expected_ci_check_desc = 'All 2 openQA jobs have passed';
    $jobs[1]->done(result => SOFTFAILED);
    is $status_reports, 5, 'the status has been reported back to GitHub as all jobs have concluded';

    # restart one of the jobs; this should lead to further status updates
    $expected_ci_check_state = 'pending';
    $expected_ci_check_desc = '1 of 2 openQA jobs is pending';
    my $clone = $jobs[1]->auto_duplicate;
    $jobs[1]->discard_changes;
    is $jobs[1]->latest_job->id, $clone->id, 'original job is no longer the latest';
    is $status_reports, 6, 'the status has been reported back to GitHub as all jobs have concluded';

    # assume the restarted just has failed; the check should now be considered failed
    $expected_ci_check_state = 'failure';
    $expected_ci_check_desc = '1 of 2 openQA jobs has failed';
    $clone->discard_changes;
    $clone->done(result => FAILED);
    is $status_reports, 7, 'the status has been reported back to GitHub as all jobs have concluded again';
};

subtest 'previous jobs are cancelled when the PR is updated/closed' => sub {
    # send a "synchronize" action via the webhook API simulating the PR was force-pushed
    $jobs->search({})->update({state => RUNNING, result => NONE});    # assume jobs are still running
    $test_payload->{action} = 'synchronize';
    $expected_ci_check_state = 'pending';
    $expected_ci_check_desc = undef;
    $t->post_ok($url, \%headers, json => $test_payload)->status_is(200, 'the hook returned success');
    ok my $pre_sp = $scheduled_products->find(2), 'the previous scheduled product still exists' or return;
    is $pre_sp->status, CANCELLED, 'the previous scheduled product has been cancelled';
    ok my $new_sp = $scheduled_products->find(3), 'a new scheduled product has been created' or return;
    is $new_sp->status, ADDED, 'the new scheduled product has just been added';

    # send a "closed" action via the webhook API simulating the PR was closed
    $test_payload->{action} = 'closed';
    $t->post_ok($url, \%headers, json => $test_payload)->status_is(200, 'the hook returned success');
    $new_sp->discard_changes;
    is $new_sp->status, CANCELLED, 'new scheduled product has been cancelled';
    is $scheduled_products->count, 2, 'no new scheduled product has been created';
};

done_testing();
