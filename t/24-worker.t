# Copyright (C) 2016-2017 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

BEGIN {
    unshift @INC, 'lib';
}

use strict;
use warnings;
use File::Temp 'tempfile';
use OpenQA::Utils;
use OpenQA::Test::Case;
use OpenQA::Test::Database;
use OpenQA::Client;
use Test::More;
use Test::Mojo;
use Test::Warnings;
use Test::Output qw(stdout_like stderr_like);
use Test::Fatal;
#use Scalar::Utils 'refaddr';

use OpenQA::Worker::Common;
use OpenQA::Worker::Jobs;

# api_init (must be called before making other calls anyways)
like(
    exception {
        OpenQA::Worker::Common::api_init(
            {HOSTS => ['http://any_host']},
            {
                host => 'http://any_host',
            })
    },
    qr/API key.*needed/,
    'auth required'
);


OpenQA::Worker::Common::api_init(
    {HOSTS => ['this_host_should_not_exist']},
    {
        host      => 'this_host_should_not_exist',
        apikey    => '1234',
        apisecret => '4321',
    });
ok($hosts->{this_host_should_not_exist},      'entry for host created');
ok($hosts->{this_host_should_not_exist}{ua},  'user agent created');
ok($hosts->{this_host_should_not_exist}{url}, 'url object created');
is($hosts->{this_host_should_not_exist}{workerid}, undef, 'worker not registered yet');

# api_call
eval { OpenQA::Worker::Common::api_call() };
ok($@, 'no action or no worker id set');

$hosts->{this_host_should_not_exist}{workerid} = 1;
$current_host = 'this_host_should_not_exist';

sub test_via_io_loop {
    my ($test_function, $autostart) = @_;
    $autostart //= 1;
    Mojo::IOLoop->next_tick($test_function);
    Mojo::IOLoop->start if $autostart;
}

test_via_io_loop sub {
    OpenQA::Worker::Common::api_call(
        'post', 'jobs/500/status',
        json          => {status => 'RUNNING'},
        ignore_errors => 1,
        tries         => 1,
        callback => sub { my $res = shift; is($res, undef, 'error ignored') });

    stderr_like(
        sub {
            OpenQA::Worker::Common::api_call(
                'post', 'jobs/500/status',
                json  => {status => 'RUNNING'},
                tries => 1,
                callback => sub { my $res = shift; is($res, undef, 'error handled'); Mojo::IOLoop->stop() });
            while (Mojo::IOLoop->is_running) { Mojo::IOLoop->singleton->reactor->one_tick }
        },
        qr/.*\[ERROR\] Connection error:.*(remaining tries: 0).*/i,
        'warning about 503 error'
    );
};

# reset settings, previous error handler removed them
$hosts->{this_host_should_not_exist}{workerid} = 1;
$current_host = 'this_host_should_not_exist';

test_via_io_loop sub {
    ok(
        OpenQA::Worker::Common::api_call(
            'post', 'jobs/500/status',
            json          => {status => 'RUNNING'},
            ignore_errors => 1,
            tries         => 1
        ),
        'api_call without callback does not fail'
    );
    Mojo::IOLoop->stop;
};

$ENV{OPENQA_CONFIG} = 't';
open(my $fh, '>>', $ENV{OPENQA_CONFIG} . '/client.conf') or die 'can not open client.conf for appending';
print $fh "[host1]\nkey=1234\nsecret=1234\n";
print $fh "[host2]\nkey=1234\nsecret=1234\n";
print $fh "[host3]\nkey=1234\nsecret=1234\n";
close $fh or die 'can not close client.conf after writing';

subtest 'api init with multiple webuis' => sub {
    OpenQA::Worker::Common::api_init({HOSTS => ['host1', 'host2', 'host3']});
    for my $h (qw(host1 host2 host3)) {
        ok($hosts->{$h},      "host $h entry present");
        ok($hosts->{$h}{ua},  "ua object for $h present");
        ok($hosts->{$h}{url}, "url object for $h present");
        is($hosts->{$h}{workerid}, undef, "worker not registered after api_init for $h");
    }
};

no warnings 'redefine';
# redefine imported api_call within OpenQA::Worker::Jobs
sub api_call_return_job {
    my %args = @_;
    $args{callback}->({job => {id => 10}});
}

# simulate we accepted the job
sub fake_start_job {
    my $host = shift;
    $OpenQA::Worker::Common::job = "job set from $host";
    Mojo::IOLoop->stop();
}

$hosts->{host1}{workerid} = 2;
$hosts->{host2}{workerid} = 2;

subtest 'check_job works when no job, then is ignored' => sub {
    my $original_api_call  = \&OpenQA::Worker::Jobs::api_call;
    my $original_start_job = \&OpenQA::Worker::Jobs::start_job;
    *OpenQA::Worker::Jobs::api_call  = \&api_call_return_job;
    *OpenQA::Worker::Jobs::start_job = \&fake_start_job;

    test_via_io_loop sub { OpenQA::Worker::Jobs::check_job('host1') };
    while (Mojo::IOLoop->is_running) { Mojo::IOLoop->singleton->reactor->one_tick }
    is($OpenQA::Worker::Common::job, 'job set from host1', 'job set');

    test_via_io_loop sub { OpenQA::Worker::Jobs::check_job('host2'); Mojo::IOLoop->stop };
    while (Mojo::IOLoop->is_running) { Mojo::IOLoop->singleton->reactor->one_tick }
    is($OpenQA::Worker::Common::job, 'job set from host1', 'job still the same');

    *OpenQA::Worker::Jobs::api_call  = $original_api_call;
    *OpenQA::Worker::Jobs::start_job = $original_start_job;
};

subtest 'test timer helpers' => sub {
    my $t_recurrent = add_timer('recurrent', 5, sub { 1 });
    ok(Mojo::IOLoop->singleton->reactor->{timers}{$t_recurrent},            'timer registered in reactor');
    ok(Mojo::IOLoop->singleton->reactor->{timers}{$t_recurrent}{recurring}, 'timer is recurrent');
    # add singleshot timer
    my $t_single = add_timer('single', 6, sub { 1 }, 1);
    ok(Mojo::IOLoop->singleton->reactor->{timers}{$t_single},             'timer registered in reactor');
    ok(!Mojo::IOLoop->singleton->reactor->{timers}{$t_single}{recurring}, 'timer is not recurrent');
    # remove timer
    remove_timer('nonexistent');
    remove_timer($t_single);
    ok(!Mojo::IOLoop->singleton->reactor->{timers}{$t_single}, 'timer removed by timerid');
    remove_timer('recurrent');
    ok(!Mojo::IOLoop->singleton->reactor->{timers}{$t_recurrent}, 'timer removed by timer mapping');
    # change timer
    is(change_timer('nonexistent'), undef, 'no timer id when trying to change nonexistent timer');
    #my $xref = refaddr $x;
    $t_recurrent = add_timer('recurrent', 5, sub { 1 });
    is(Mojo::IOLoop->singleton->reactor->{timers}{$t_recurrent}{after}, 5, 'timer registered for 5s');
    my $x = Mojo::IOLoop->singleton->reactor->{timers}{$t_recurrent}{cb};
    $t_recurrent = change_timer('recurrent', 10);
    is(Mojo::IOLoop->singleton->reactor->{timers}{$t_recurrent}{after},  10, 'timer registered for 10s');
    is(Mojo::IOLoop->singleton->reactor->{timers}{$t_recurrent}{cb}->(), 1,  'timer function match x');
    $t_recurrent = change_timer('recurrent', 6, sub { 2 });
    is(Mojo::IOLoop->singleton->reactor->{timers}{$t_recurrent}{after},  6, 'timer registered for 6s');
    is(Mojo::IOLoop->singleton->reactor->{timers}{$t_recurrent}{cb}->(), 2, 'timer function match y');
};

sub remove_timers {
    # clean all timers from previous tests
    for my $t (get_timers(), 'register_worker') {
        remove_timer($t);
    }
}

undef $ENV{OPENQA_CONFIG};
$ENV{MOJO_LOG_LEVEL} = 'warn';
my $schema = OpenQA::Test::Database->new->create;
my $t      = Test::Mojo->new('OpenQA::WebAPI');
$t->app->log->level('warn');

my $response_code  = 200;
my $response_data  = '';
my $expected_abort = '';
my $job_checked    = 0;

sub fake_stop_job {
    my ($abort_reason, $jobid) = @_;
    is($abort_reason, $expected_abort, "$abort_reason == $expected_abort");
}

sub fake_check_job {
    $job_checked = 1;
}

sub test_working_environment {
    my ($registered) = @_;

    if ($registered) {
        # check timers, worker id, ws, ... when worker is registered ok
    }
    else {
        # check everything in order when not registered
    }
}

$t->app->hook(
    before_dispatch => sub {
        my $c = shift;
        if ($response_code) {
            $c->render(text => $response_data, status => $response_code);
        }
        else {
            return;
        }
    });

# override websocket route
my $r = $t->ua->server->app->routes;
$r->find('worker_websockets')->remove;
$r->websocket(
    '/api/v1/ws/:workerid' => [workerid => qr/\d+/] => sub {
        my $c        = shift;
        my $workerid = $c->param('workerid');
        ok($workerid, 'worker id provided during websocket registration');
        $c->on(json   => sub { });
        $c->on(finish => sub { });
    });

subtest 'register worker tests' => sub {
    no warnings 'redefine';
    my $original_stop_job = \&OpenQA::Worker::Jobs::stop_job;
    *OpenQA::Worker::Jobs::stop_job = \&fake_stop_job;
    my $original_check_job = \&OpenQA::Worker::Jobs::check_job;
    *OpenQA::Worker::Jobs::check_job = \&fake_check_job;

    remove_timers;
    my $test_host = $t->ua->server->url->host_port;
    OpenQA::Worker::Common::api_init(
        {HOSTS => [$test_host]},
        {
            apikey    => 'PERCIVALKEY02',
            apisecret => 'PERCIVALSECRET02',
        });
    ok($hosts->{$test_host}, 'Mojo::Test api initialized');

    # connection refused
    # TODO

    # refused by unknown worker 404
    $response_data = 'worker rejected';
    $response_code = 404;

    stderr_like(
        sub {
            OpenQA::Worker::Common::register_worker($test_host);
            # need to wait here until non-blocking register call finishes
            while ($hosts->{$test_host}) {
                Mojo::IOLoop->one_tick;
            }
        },
        qr/ignoring server - server refused with code 404: worker rejected/,
        'correct error on 404'
    );
    pass('host removed by worker');
    remove_timers;

    # refused by unknown api keys 503
    OpenQA::Worker::Common::api_init(
        {HOSTS => [$test_host]},
        {
            apikey    => 'PERCIVALKEY02',
            apisecret => 'PERCIVALSECRET02',
        });
    ok($hosts->{$test_host}, 'Mojo::Test api initialized');
    $response_data = 'api key rejected';
    $response_code = 503;

    stderr_like(
        sub {
            OpenQA::Worker::Common::register_worker($test_host);
            # need to wait here until non-blocking register call finishes
            while (!$hosts->{$test_host}{timers}{register_worker}) {
                Mojo::IOLoop->one_tick;
            }
        },
        qr/503:api key rejected, retry in 10s/,
        'correct error on 503'
    );
    pass('Register worker timer added after 503');
    remove_timers;

    # accepted 200
    undef $response_code;
    OpenQA::Worker::Common::register_worker($test_host);
    # need to wait here until non-blocking register call finishes
    while (!($hosts->{$test_host}{workerid} && $hosts->{$test_host}{ws})) {
        Mojo::IOLoop->one_tick;
    }
    ok($hosts->{$test_host}{workerid}, 'Mojo::Test api registered');
    ok($job_checked,                   'Job was checked as part of successful register call');

    # worker reregistration
    $job_checked = 0;
    my $ws = $hosts->{$test_host}{ws};
    OpenQA::Worker::Common::register_worker($test_host);
    # need to wait here until non-blocking register call finishes
    while (!($hosts->{$test_host}{workerid} && $hosts->{$test_host}{ws})) {
        Mojo::IOLoop->one_tick;
    }
    ok($hosts->{$test_host}{workerid}, 'Mojo::Test api registered');
    ok($job_checked,                   'Job was checked as part of successful register call');
    isnt($ws, $hosts->{$test_host}{ws}, 'WS connection is new after reregistration');

    *OpenQA::Worker::Jobs::start_job = $original_stop_job;
    *OpenQA::Worker::Jobs::start_job = $original_check_job;
};

# subtest 'API calls handling' => sub {
#     $OpenQA::Worker::Common::current_host = $test_host;
#     # all ok - no timer for retry, no worker registration
#     $responseCode = 200;
#     test_via_io_loop sub {
#         ok(
#             OpenQA::Worker::Common::api_call(
#                 'post', 'jobs/500/status',
#                 json     => {status => 'RUNNING'},
#                 callback => sub     { Mojo::IOLoop->stop }
#             ),
#             'test'
#         );
#     };
#     ok(!check_timer('retry'),     'retry timer not set for response 200');
#     ok(!check_timer('reconnect'), 'timer not set for response 200');
#
#     # 404 - no retry, worker registration scheduled
#     $responseCode   = 404;
#     $expected_abort = 'api-failure';
#     test_via_io_loop(
#         sub {
#             ok(
#                 OpenQA::Worker::Common::api_call(
#                     'post', 'jobs/500/status',
#                     json     => {status => 'RUNNING'},
#                     callback => sub     { Mojo::IOLoop->stop }
#                 ),
#                 'test'
#             );
#         },
#         0
#     );
#     ok(!check_timer('retry'),    'retry timer not set for response 404');
#     ok(check_timer('reconnect'), 'reconnect timer set for response 404');
#
#     # 503 - retry timer
#     # 200 after 503 - ok
#     $responseCode = 503;
#     test_via_io_loop sub {
#         ok(
#             OpenQA::Worker::Common::api_call(
#                 'post', 'jobs/500/status',
#                 json     => {status => 'RUNNING'},
#                 tries    => 1,
#                 callback => sub     { Mojo::IOLoop->stop }
#             ),
#             'test'
#         );
#     };
#     ok(!check_timer('reconnect'), 'reconnect timer not set yet for response 503');
#     ok(check_timer('retry'),      'retry timer set for 503');
#     # modify timer
#     $responseCode = 200;
#     test_via_io_loop sub {
#
#     };
#     ok(!check_timer('reconnect'), 'reconnect timer not set after 200 response');
#     ok(!check_timer('retry'),     'retry timer not set for 200');
#
#     # 503 - retry timer
#     # 503 after 503 - worker registration scheduled
#
#     $responseCode = 503;
#     test_via_io_loop sub {
#         ok(
#             OpenQA::Worker::Common::api_call(
#                 'post', 'jobs/500/status',
#                 json     => {status => 'RUNNING'},
#                 tries    => 1,
#                 callback => sub     { Mojo::IOLoop->stop }
#             ),
#             'test'
#         );
#     };
#     ok(!check_timer('reconnect'), 'reconnect timer not set yet for response 503');
#     ok(check_timer('retry'),      'retry timer set for 503');
#     test_via_io_loop sub {
#         ok(
#             OpenQA::Worker::Common::api_call(
#                 'post', 'jobs/500/status',
#                 json     => {status => 'RUNNING'},
#                 tries    => 1,
#                 callback => sub     { Mojo::IOLoop->stop }
#             ),
#             'test'
#         );
#     };
#     ok(check_timer('reconnect'), 'reconnect timer set for response 503');
#     ok(!check_timer('retry'),    'no retry timer set after tree retries');
# };

done_testing();
