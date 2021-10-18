#!/usr/bin/env perl
# Copyright 2016-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Jobs::Constants;
use OpenQA::Test::Client 'client';
use OpenQA::Test::Database;
use OpenQA::Test::TimeLimit '10';
use Test::Output qw(combined_like combined_unlike);
use Test::MockModule;
use Test::Mojo;
use Test::Warnings ':report_warnings';
use Mojo::File qw(tempdir path);
use Mojo::JSON qw(decode_json);
use Mojo::IOLoop;
use OpenQA::WebAPI::Plugin::AMQP;

my $plugin_mock = Test::MockModule->new('OpenQA::WebAPI::Plugin::AMQP');
my %published;
$plugin_mock->redefine(
    publish_amqp => sub {
        my ($self, $topic, $data) = @_;
        $published{$topic} = $data;
    });

OpenQA::Test::Database->new->create(fixtures_glob => '01-jobs.pl 03-users.pl 05-job_modules.pl');

# this test also serves to test plugin loading via config file
my $conf = "[global]\nplugins=AMQP\n[amqp]\npublish_attempts = 2\npublish_retry_delay = 0\n";
my $tempdir = tempdir;
path($ENV{OPENQA_CONFIG} = $tempdir)->make_path->child('openqa.ini')->spurt($conf);

my $t = client(Test::Mojo->new('OpenQA::WebAPI'));
my $app = $t->app;

# create a parent group
my $schema = $app->schema;
my $parent_groups = $schema->resultset('JobGroupParents');
$parent_groups->create({id => 2000, name => 'test'});

my $settings = {
    DISTRI => 'Unicorn',
    FLAVOR => 'pink',
    VERSION => '42',
    BUILD => '666',
    TEST => 'rainbow',
    ISO => 'whatever.iso',
    DESKTOP => 'DESKTOP',
    KVM => 'KVM',
    ISO_MAXSIZE => 1,
    MACHINE => 'RainbowPC',
    ARCH => 'x86_64'
};

# create a job via API
my $job;
subtest 'create job' => sub {
    $t->post_ok('/api/v1/jobs' => form => $settings)->status_is(200);
    ok($job = $t->tx->res->json->{id}, 'got ID of new job');
    is_deeply(
        $published{'suse.openqa.job.create'},
        {
            ARCH => 'x86_64',
            BUILD => '666',
            DESKTOP => 'DESKTOP',
            DISTRI => 'Unicorn',
            FLAVOR => 'pink',
            ISO => 'whatever.iso',
            ISO_MAXSIZE => 1,
            KVM => 'KVM',
            MACHINE => 'RainbowPC',
            TEST => 'rainbow',
            VERSION => 42,
            group_id => undef,
            id => $job,
            remaining => 1
        },
        'job create triggers amqp'
    );
};

subtest 'mark job as done' => sub {
    $t->post_ok("/api/v1/jobs/$job/set_done")->status_is(200);
    is_deeply(
        $published{'suse.openqa.job.done'},
        {
            ARCH => 'x86_64',
            BUILD => '666',
            FLAVOR => 'pink',
            ISO => 'whatever.iso',
            MACHINE => 'RainbowPC',
            TEST => 'rainbow',
            bugref => undef,
            group_id => undef,
            id => $job,
            newbuild => undef,
            remaining => 0,
            result => INCOMPLETE,
            reason => undef,
        },
        'job done triggers amqp'
    );
};

subtest 'mark job with taken over bugref as done' => sub {
    # prepare previous job of 99963 to test carry over
    my $jobs = $schema->resultset('Jobs');
    my $previous_job = $jobs->find(99962);
    $previous_job->comments->create(
        {
            text => 'bsc#123',
            user_id => $schema->resultset('Users')->first->id,
        });
    is($previous_job->bugref, 'bsc#123', 'added bugref recognized');

    # mark so far running job 99963 as failed which should trigger bug carry over
    $t->post_ok(
        '/api/v1/jobs/99963/set_done',
        form => {
            result => OpenQA::Jobs::Constants::FAILED
        })->status_is(200);
    is_deeply(
        $published{'suse.openqa.job.done'},
        {
            ARCH => 'x86_64',
            BUILD => '0091',
            FLAVOR => 'DVD',
            ISO => 'openSUSE-13.1-DVD-x86_64-Build0091-Media.iso',
            MACHINE => '64bit',
            TEST => 'kde',
            bugref => 'bsc#123',
            bugurl => 'https://bugzilla.suse.com/show_bug.cgi?id=123',
            group_id => 1001,
            id => 99963,
            newbuild => undef,
            remaining => 3,
            result => 'failed',
            reason => undef,
        },
        'carried over bugref and resolved URL present in AMQP event'
    );
};

subtest 'duplicate and cancel job' => sub {
    $t->post_ok("/api/v1/jobs/$job/duplicate")->status_is(200);
    my $newjob = $t->tx->res->json->{id};
    is_deeply(
        $published{'suse.openqa.job.restart'},
        {
            id => $job,
            result => {$job => $newjob},
            auto => 0,
            ARCH => 'x86_64',
            BUILD => '666',
            FLAVOR => 'pink',
            ISO => 'whatever.iso',
            MACHINE => 'RainbowPC',
            TEST => 'rainbow',
            bugref => undef,
            group_id => undef,
            remaining => 1,
        },
        'job duplicate triggers amqp'
    );

    $t->post_ok("/api/v1/jobs/$newjob/cancel")->status_is(200);
    is_deeply(
        $published{'suse.openqa.job.cancel'},
        {
            ARCH => 'x86_64',
            BUILD => '666',
            FLAVOR => 'pink',
            ISO => 'whatever.iso',
            MACHINE => 'RainbowPC',
            TEST => 'rainbow',
            group_id => undef,
            id => $newjob,
            remaining => 0
        },
        'job cancel triggers amqp'
    );
};

sub assert_common_comment_json {
    my ($json) = @_;
    ok($json->{id}, 'id');
    is($json->{job_id}, undef, 'job id');
    is($json->{text}, 'test', 'text');
    is($json->{user}, 'perci', 'user');
    ok($json->{created}, 't_created');
    ok($json->{updated}, 't_updated');
}

subtest 'create job group comment' => sub {
    $t->post_ok('/api/v1/groups/1001/comments' => form => {text => 'test'})->status_is(200);
    my $json = $published{'suse.openqa.comment.create'};
    assert_common_comment_json($json);
    is($json->{group_id}, 1001, 'job group id');
    is($json->{parent_group_id}, undef, 'parent group id');
};

subtest 'create parent group comment' => sub {
    $t->post_ok('/api/v1/parent_groups/2000/comments' => form => {text => 'test'})->status_is(200);
    my $json = $published{'suse.openqa.comment.create'};
    assert_common_comment_json($json);
    is($json->{group_id}, undef, 'job group id');
    is($json->{parent_group_id}, 2000, 'parent group id');
};

$app->config->{amqp}{topic_prefix} = '';

subtest 'publish without topic prefix' => sub {
    $t->post_ok('/api/v1/jobs' => form => $settings)->status_is(200);
    is($published{'openqa.job.create'}->{ARCH}, 'x86_64', 'got message with correct topic');
};

# Now let's unmock publish_amqp so we can test it...
$plugin_mock->unmock('publish_amqp');
%published = ();
# ...but we'll mock the thing it calls.
my $publisher_mock = Test::MockModule->new('Mojo::RabbitMQ::Client::Publisher');
my ($last_publisher, $last_promise);
$publisher_mock->redefine(
    publish_p => sub {
        $last_publisher = shift;
        # copied from upstream git master as of 2019-07-24
        my $body = shift;
        my $headers = {};
        my %args = ();

        if (ref($_[0]) eq 'HASH') {
            $headers = shift;
        }
        if (@_) {
            %args = (@_);
        }
        # end copying
        $published{body} = $body;
        $published{headers} = $headers;
        $published{args} = \%args;
        return $last_promise = Mojo::Promise->new;
    });

# we need an instance of the plugin now. I can't find a documented
# way to access the one that's already loaded...
my $amqp = OpenQA::WebAPI::Plugin::AMQP->new;
$amqp->register($app);

subtest 'amqp_publish call without headers' => sub {
    $amqp->publish_amqp('some.topic', 'some message');
    is($last_publisher->url, 'amqp://guest:guest@localhost:5672/?exchange=pubsub', 'url specified');
    is($published{body}, 'some message', 'message body correctly passed');
    is_deeply($published{headers}, {}, 'headers is empty hashref');
    is_deeply($published{args}->{routing_key}, 'some.topic', 'topic appears as routing key');
};

subtest 'amqp_publish call with reference as body' => sub {
    %published = ();
    my $body = {field => 'value'};
    $amqp->publish_amqp('some.topic', $body);
    is($published{body}, $body, 'message body kept as ref not encoded by publish_amqp');
    is_deeply($published{args}->{routing_key}, 'some.topic', 'topic appears as routing key');
};

subtest 'amqp_publish call with headers' => sub {
    %published = ();
    $amqp->publish_amqp('some.topic', 'some message', {'someheader' => 'something'});
    is($published{body}, 'some message', 'message body correctly passed');
    is_deeply($published{headers}, {'someheader' => 'something'}, 'headers is expected hashref');
    is_deeply($published{args}->{routing_key}, 'some.topic', 'topic appears as routing key');

    $app->log(Mojo::Log->new(level => 'debug'));
    combined_like { $amqp->publish_amqp('some.topic', 'some message', 'some headers') } qr/headers are not a hashref/,
      'error logged if headers are no hashref';
};

subtest 'promise handlers' => sub {
    combined_like { $amqp->publish_amqp('some.topic', {}) } qr/Sending.*some\.topic/, 'publishing logged (1)';
    combined_like { $last_promise->resolve(1); $last_promise->wait } qr/some\.topic published/, 'success logged';
    combined_like { $amqp->publish_amqp('some.topic', {}) } qr/Sending.*some\.topic/, 'publishing logged (2)';
    my $previous_promise = $last_promise;
    combined_like { $last_promise->reject('some error'); $last_promise->wait }
    qr/Publishing some\.topic failed: some error \(1 attempts left\)/, 'failure logged, 1 attempt remaining';
    combined_like { Mojo::IOLoop->one_tick } qr/Sending.*some\.topic/, 'trying to publish the event again';
    isnt $last_promise, $previous_promise, 'another promise has been made (to re-try)';
    $previous_promise = $last_promise;
    combined_like { $last_promise->reject('some error'); $last_promise->wait }
    qr/Publishing some\.topic failed: some error \(0 attempts left\)/, 'failure logged, no attempts remaining';
    combined_unlike { Mojo::IOLoop->one_tick } qr/Sending.*some\.topic/, 'no further retry logged';
    is $last_promise, $previous_promise, 'no further promise has been made (running out of retries)';
};

done_testing();
