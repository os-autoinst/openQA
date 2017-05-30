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
use FindBin;
use lib "$FindBin::Bin/lib";
use OpenQA::Utils;
use OpenQA::Test::Case;
use OpenQA::Client;
use Test::More;
use Test::Mojo;
use Test::Warnings;
use Test::Output qw(stdout_like stderr_like);
use Test::Fatal;
use Mojo::File qw(tempdir path);
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
    my ($test_function) = @_;
    add_timer('call', 0, $test_function, 1);
    Mojo::IOLoop->start;
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

my @conf = ("[global]\n", "plugins=AMQP\n");
$ENV{OPENQA_CONFIG} = tempdir;
path($FindBin::Bin, "data")->child("client.conf")->copy_to(path($ENV{OPENQA_CONFIG})->make_path->child("client.conf"));
ok -e path($ENV{OPENQA_CONFIG})->child('client.conf')->to_string;
open(my $fh, '>>', path($ENV{OPENQA_CONFIG})->child('client.conf')->to_string)
  or die 'can not open client.conf for appending';
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
sub api_call {
    my %args = @_;
    $args{callback}->({job => {id => 10}});
}
*OpenQA::Worker::Jobs::api_call = \&api_call;

# simulate we accepted the job
sub OpenQA::Worker::Jobs::start_job {
    my $host = shift;
    $OpenQA::Worker::Common::job = "job set from $host";
    Mojo::IOLoop->stop();
}

$hosts->{host1}{workerid} = 2;
$hosts->{host2}{workerid} = 2;

subtest 'check_job works when no job, then is ignored' => sub {
    test_via_io_loop sub { OpenQA::Worker::Jobs::check_job('host1') };
    while (Mojo::IOLoop->is_running) { Mojo::IOLoop->singleton->reactor->one_tick }
    is($OpenQA::Worker::Common::job, 'job set from host1', 'job set');

    test_via_io_loop sub { OpenQA::Worker::Jobs::check_job('host2'); Mojo::IOLoop->stop };
    while (Mojo::IOLoop->is_running) { Mojo::IOLoop->singleton->reactor->one_tick }
    is($OpenQA::Worker::Common::job, 'job set from host1', 'job still the same');
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

# Ensure stop_job gets executed to avoid uncovered changes in codecov
subtest 'mock test stop_job' => sub {
    use Mojo::Util 'monkey_patch';
    $OpenQA::Worker::Common::job = {id => 9999};
    $OpenQA::Worker::Common::verbose = 1;

    my $stop_job = 0;
    monkey_patch 'Mojo::IOLoop', timer => sub {
        $stop_job = 1;
    };
    monkey_patch 'OpenQA::Worker::Jobs', upload_status => sub {
        1;
    };
    OpenQA::Worker::Jobs::update_status;

    OpenQA::Worker::Jobs::stop_job(0, 9999);
    is $stop_job, 1, "stop_job() reached";
};

done_testing();
