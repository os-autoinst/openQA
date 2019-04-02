# Copyright (C) 2016-2018 SUSE LLC
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
use OpenQA::Test::Utils qw(redirect_output standard_worker kill_service setup_share_dir);
use OpenQA::Client;
use Test::More;
use Test::Mojo;
use Test::MockModule;
use Test::Warnings;
use Test::Output 'combined_like';
use Test::Fatal;
use Mojo::File qw(tempdir path);
#use Scalar::Utils 'refaddr';

use OpenQA::Worker::Common;
use OpenQA::Worker::Jobs;
use OpenQA::Schema::Result::Workers ();
use OpenQA::Constants qw(WORKERS_CHECKER_THRESHOLD MAX_TIMER MIN_TIMER);

# api_init (must be called before making other calls anyways)
like(
    exception {
        OpenQA::Worker::Common::api_init(
            {HOSTS => ['http://any_host']},
            {
                host => 'http://any_host',
            });
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

sub test_timer {
    my ($i, $population) = @_;
    $OpenQA::Worker::Common::instance = $i;
    OpenQA::Worker::Common::calculate_status_timer({localhost => {population => $population}}, 'localhost');
}

sub compare_timers {
    my ($instance1, $instance2, $population) = @_;
    my $t  = test_timer($instance1, $population);
    my $t1 = test_timer($instance2, $population);
    ok $t != $t1,
      "timer between instances $instance1 and $instance2 is different in a population of $population ( $t != $t1 )";
}

test_via_io_loop sub {
    OpenQA::Worker::Common::api_call(
        'post', 'jobs/500/status',
        json          => {status => 'RUNNING'},
        ignore_errors => 1,
        tries         => 1,
        callback      => sub { my $res = shift; is($res, undef, 'error ignored') });

    combined_like(
        sub {
            OpenQA::Worker::Common::api_call(
                'post', 'jobs/500/status',
                json     => {status => 'RUNNING'},
                tries    => 1,
                callback => sub { my $res = shift; is($res, undef, 'error handled'); Mojo::IOLoop->stop() });
            while (Mojo::IOLoop->is_running) { Mojo::IOLoop->singleton->reactor->one_tick }
        },
        qr/.*\[ERROR\] Connection error:.*(remaining tries: 0).*\[DEBUG\].*no job was running.*/s,
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

my @conf    = ("[global]\n", "plugins=AMQP\n");
my $tempdir = tempdir;
$ENV{OPENQA_CONFIG} = $tempdir;
path($FindBin::Bin, "data")->child("client.conf")->copy_to(path($ENV{OPENQA_CONFIG})->make_path->child("client.conf"));
ok -e path($ENV{OPENQA_CONFIG})->child('client.conf')->to_string;
open(my $fh, '>>', path($ENV{OPENQA_CONFIG})->child('client.conf')->to_string)
  or die 'can not open client.conf for appending';
print $fh "[host1]\nkey=1234\nsecret=1234\n";
print $fh "[host2]\nkey=1234\nsecret=1234\n";
print $fh "[host3]\nkey=1234\nsecret=1234\n";
close $fh or die 'can not close client.conf after writing';

subtest 'Worker verify job' => sub {
    $OpenQA::Worker::Common::job = "foobar";

    is OpenQA::Worker::Jobs::verify_job, 0;

    $OpenQA::Worker::Common::job = {id => 9999, state => "scheduled"};

    is OpenQA::Worker::Jobs::verify_job, 1;

    OpenQA::Worker::Jobs::_reset_state();
};

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
    open(my $oldSTDOUT, ">&", STDOUT) or die "Can't preserve STDOUT\n$!\n";
    close STDOUT;
    my $stdout;
    open STDOUT, '>', \$stdout;

    test_via_io_loop sub { OpenQA::Worker::Jobs::check_job('host1') };
    while (Mojo::IOLoop->is_running) { Mojo::IOLoop->singleton->reactor->one_tick }
    is($OpenQA::Worker::Common::job, 'job set from host1', 'job set');

    test_via_io_loop sub { OpenQA::Worker::Jobs::check_job('host2'); Mojo::IOLoop->stop };
    while (Mojo::IOLoop->is_running) { Mojo::IOLoop->singleton->reactor->one_tick }
    is($OpenQA::Worker::Common::job, 'job set from host1', 'job still the same');

    my @matches = ($stdout =~ m/\[DEBUG\] ## adding timer/g);
    ok(@matches == 2, 'Adding timer log');
    @matches = ($stdout =~ m/\[DEBUG\] checking for job/g);
    ok(@matches == 1, 'Checking job');
    close STDOUT;
    open(STDOUT, '>&', $oldSTDOUT) or die "Can't dup \$oldSTDOUT: $!";
};

subtest 'test timer helpers' => sub {
    open(my $oldSTDOUT, ">&", STDOUT) or die "Can't preserve STDOUT\n$!\n";
    close STDOUT;
    my $stdout;
    open STDOUT, '>', \$stdout;

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

    my @matches = ($stdout =~ m/\[DEBUG\] ## adding timer/g);
    ok(@matches == 5, 'Adding timer log');
    @matches = ($stdout =~ m/\[DEBUG\] ## removing timer/g);
    ok(@matches == 5, 'Removing timer log');
    @matches = ($stdout =~ m/\[DEBUG\] ## changing timer/g);
    ok(@matches == 2, 'Changing timer log');

    close STDOUT;
    open(STDOUT, '>&', $oldSTDOUT) or die "Can't dup \$oldSTDOUT: $!";
};

# Ensure stop_job gets executed to avoid uncovered changes in codecov
subtest 'mock test stop_job' => sub {
    open(my $oldSTDOUT, ">&", STDOUT) or die "Can't preserve STDOUT\n$!\n";
    close STDOUT;
    my $stdout;
    open STDOUT, '>', \$stdout;

    use Mojo::Util 'monkey_patch';
    $OpenQA::Worker::Common::job = {id => 9999};

    my $stop_job = 0;
    monkey_patch 'Mojo::IOLoop', timer => sub {
        $stop_job = 1;
    };
    monkey_patch 'OpenQA::Worker::Jobs', upload_status => sub {
        1;
    };
    OpenQA::Worker::Jobs::update_status;

    OpenQA::Worker::Jobs::stop_job(0, 9999);
    is($stop_job, 1, "stop_job() reached");
    print STDERR $stdout;
    my @matches = ($stdout =~ m/\[DEBUG\] updating status/g);
    my $ok      = is(scalar @matches, 1, 'Updating status log');
    @matches = ($stdout =~ m/\[DEBUG\] stop_job/g);
    $ok      = is(scalar @matches, 1, 'Stop job log') && $ok;
    @matches = ($stdout =~ m/\[DEBUG\] ## removing timer/g);
    $ok      = is(scalar @matches, 2, 'Changing timer log') && $ok;
    @matches = ($stdout =~ m/\[DEBUG\] postpone stopping until ongoing status update is concluded/g);
    $ok      = is(scalar @matches, 1, 'Waiting for update status log') && $ok;
    diag explain $stdout unless $ok;

    close STDOUT;
    open(STDOUT, '>&', $oldSTDOUT) or die "Can't dup \$oldSTDOUT: $!";
};

subtest 'worker configuration reading' => sub {
    my $configdir = tempdir();
    local $ENV{OPENQA_CONFIG} = $configdir;
    my $ini = $configdir->child('workers.ini');
    $ini->spurt(
        <<EOF
# Configuration of the workers and their backends.
[global]
CACHEDIRECTORY = /var/lib/openqa/cache
HOST = localhost foobar
FOO_BAR_BAZ = 6
[1]
WORKER_CLASS = tap,qemu_x86_64,caasp_x86_64
CACHEDIRECTORY = /var/lib/openqa/cache
[2]
WORKER_CLASS = tap,qemu_x86_64,caasp_x86_64
CACHEDIRECTORY = /var/lib/openqa/cache
[3]
WORKER_CLASS = tap,qemu_x86_64,caasp_x86_64
CACHEDIRECTORY = /var/lib/openqa/cache
EOF
    );

    my ($w_setting, $h_setting) = OpenQA::Worker::Common::read_worker_config(1, 'localhost');
    is $w_setting->{FOO_BAR_BAZ}, 6, 'Additional global options are in worker setting' or diag explain $w_setting;
    is $w_setting->{CACHEDIRECTORY}, '/var/lib/openqa/cache'        or diag explain $w_setting;
    is $w_setting->{WORKER_CLASS},   'tap,qemu_x86_64,caasp_x86_64' or diag explain $w_setting;
    is $h_setting->{HOSTS}->[0], 'localhost' or diag explain $h_setting;
    is_deeply $h_setting->{localhost}, {} or diag explain $h_setting;

    my $j = {settings => {}};
    OpenQA::Worker::Jobs::copy_job_settings($j, $w_setting);

    is($j->{settings}->{FOO_BAR_BAZ}, 6, 'Worker settings are copied to the job settings') or diag explain $job;
    is($j->{settings}->{CACHEDIRECTORY}, '/var/lib/openqa/cache', 'Worker  settings are copied to the job settings')
      or diag explain $j;
    is(
        $j->{settings}->{WORKER_CLASS},
        'tap,qemu_x86_64,caasp_x86_64',
        'Worker  settings are copied to the job settings'
    ) or diag explain $j;
};

subtest 'worker status timer calculation' => sub {
    $OpenQA::Worker::Common::worker_settings = {};

    # Or we would see workers detected as dead
    ok((WORKERS_CHECKER_THRESHOLD - MAX_TIMER) >= 20,
        "WORKERS_CHECKER_THRESHOLD is bigger than MAX_TIMER at least by 20s");
    my $instance = 1;
    my $pop      = $instance;
    do {
        $pop++;
        my $t = test_timer($instance, $pop);
        ok in_range($t, 70, 90), "timer $t for instance $instance in range with worker population of $pop";
      }
      for $instance .. 10;

    $instance = 25;
    $pop      = $instance;
         compare_timers(7, 9, ++$pop)
      && compare_timers(5, 10,        $pop)
      && compare_timers(4, $instance, $pop)
      && compare_timers(9, 10,        $pop)
      for $instance .. 30;

    $instance = 205;
    $pop      = $instance;
    compare_timers(40, 190, ++$pop)
      && compare_timers(30, 200, $pop)
      && compare_timers(70, 254, $pop)
      for $instance .. 300;

    $pop = 1;
    ok in_range(test_timer(int(rand_range(1, $pop)), ++$pop), MIN_TIMER, MAX_TIMER),
      "timer in range with worker population of $pop"
      for 1 .. 999;
};

subtest 'mock test send_status' => sub {
    $OpenQA::Worker::Common::job = {id => 9999, state => "scheduled"};

    my $faketx = FakeTx->new;
    OpenQA::Worker::Common::send_status($faketx);

    is($faketx->get(0)->{status},       "working");
    is($faketx->get(0)->{job}->{state}, "scheduled");
    is($faketx->get(0)->{type},         "worker_status");
    is(keys %{$faketx->get(0)},         3);

    $OpenQA::Worker::Common::job = {};

    OpenQA::Worker::Common::send_status($faketx);

    is($faketx->get(1)->{status}, "free");
    ok(!exists $faketx->get(1)->{job}->{state});
    is($faketx->get(1)->{type}, "worker_status");
    is(keys %{$faketx->get(1)}, 3);

    $OpenQA::Worker::Common::job = undef;

    OpenQA::Worker::Common::send_status($faketx);

    is($faketx->get(2)->{status}, "free");
    ok(!exists $faketx->get(2)->{job}->{state});
    is($faketx->get(2)->{type}, "worker_status");
    is(keys %{$faketx->get(2)}, 3);

    $OpenQA::Worker::Common::job = {id => 9999, state => "running", settings => {NAME => "Foo"}};
    OpenQA::Worker::Common::send_status($faketx);
    is($faketx->get(3)->{status},       "working");
    is($faketx->get(3)->{job}->{state}, "running");
    is($faketx->get(3)->{type},         "worker_status");
    is(keys %{$faketx->get(3)},         3);

    OpenQA::Worker::Jobs::_reset_state();
    OpenQA::Worker::Common::send_status($faketx);
    is($faketx->get(4)->{status}, "free");
    ok(!exists $faketx->get(4)->{job}->{state});
    is($faketx->get(4)->{type}, "worker_status");
    is(keys %{$faketx->get(4)}, 3);
};


subtest 'Worker logs' => sub {
    path($FindBin::Bin, "data")->child("workers.ini")->copy_to(path($ENV{OPENQA_CONFIG})->child("workers.ini"));

    local $ENV{OPENQA_LOGFILE} = undef;
    local $ENV{MOJO_LOG_LEVEL} = 'debug';

    my @re = (
        '\[debug\]( \[pid:\d+\])? Found possible working directory for .*?: .*',
        '\[error\]( \[pid:\d+\])? Ignoring host .*: Working directory does not exist'
    );
    my $c = join('\n', @re);

    combined_like sub {
        my $worker_pid = standard_worker('123', '456', "http://bogushost:999999", 1);
        sleep 5;
        kill_service $worker_pid, 1;
    }, qr/$c/;

    path($ENV{OPENQA_CONFIG})->child("workers.ini")->spurt("");
    my $prjdir = tempdir;
    $OpenQA::Utils::prjdir = $prjdir->child('openqa');

    @re = (
        '\[info\]( \[pid:\d+\])? Project dir for host .*? is .*',
        '\[info\]( \[pid:\d+\])? registering worker .*? version \d+ with openQA .*? using protocol version .*',
        '\[error\]( \[pid:\d+\])? unable to connect to host .* retry in .*',
        '\[debug\]( \[pid:\d+\])? ## adding timer register_worker-.*'
    );

    $c = join('\n', @re);

    my $sharedir = path($OpenQA::Utils::prjdir, 'share')->make_path;
    combined_like(
        sub {
            my $worker_pid = standard_worker('123', '456', "http://bogushost:999999", 1);
            sleep 5;
            kill_service $worker_pid, 1;
            path($OpenQA::Utils::prjdir)->remove_tree;
        },
        qr/$c/
    );
};

subtest 'Worker websocket messages' => sub {
    use OpenQA::Worker::Commands;
    combined_like sub { OpenQA::Worker::Commands::websocket_commands(undef, {fooo => undef}) },
      qr/Received WS message without type!/;
    combined_like sub { OpenQA::Worker::Commands::websocket_commands(FakeTx->new, {type => 'foo'}) },
      qr/got unknown command/;
};

subtest 'handling upload finished' => sub {
    # setup mocking for stop_job and upload_images
    my $worker_jobs_mock = Test::MockModule->new('OpenQA::Worker::Jobs');
    my $stop_job_aborted = 0;
    $worker_jobs_mock->mock(
        stop_job => sub {
            my ($aborted) = @_;
            fail('stop_job called while upload status still running')
              if (OpenQA::Worker::Jobs::is_upload_status_running);
            fail('stop_job unexpectedly called multiple times') if ($stop_job_aborted);
            $stop_job_aborted = $aborted;
        });
    my $upload_images_called = 0;
    my $upload_images_result = 0;
    $worker_jobs_mock->mock(
        upload_images => sub {
            fail('image upload called after job already aborted')    if ($stop_job_aborted);
            fail('upload_images unexpectedly called multiple times') if ($upload_images_called);
            $upload_images_called = 1;
            return $upload_images_result;
        });
    # manipulate whether the developer session has been started
    my $is_developer_session_started_res = 0;
    $worker_jobs_mock->mock(
        is_developer_session_started => sub {
            return $is_developer_session_started_res;
        });
    # assert that post to livehandler only happens if developer session has been started
    $worker_jobs_mock->mock(
        post_upload_progress_to_liveviewhandler => sub {
            fail('post_upload_progress_to_liveviewhandler unexpectedly called');
        });

    # define arguments to pass
    my ($job_id, $upload_up_to) = (42, 'some module');
    my $callback_called = 0;
    my $callback        = sub {
        fail('callback unexpectedly called');
    };
    my $callback2 = sub {
        $callback_called = 1;
    };

    subtest 'behavor when result for status upload is undef' => sub {
        OpenQA::Worker::Jobs::handle_status_upload_finished(1, $job_id, $upload_up_to, $callback2, undef);
        is($stop_job_aborted, 0, 'undefined status upload result on final status update is ignored');
        is($callback_called,  1, 'callback also in the error case called');

        OpenQA::Worker::Jobs::handle_status_upload_finished(0, $job_id, $upload_up_to, $callback, undef);
        is($stop_job_aborted,     'api-failure', 'undefined status upload result is considered an API failure');
        is($upload_images_called, 0,             'no image upload if status upload result is undef');
    };

    subtest 'behavior when image upload fails' => sub {
        $callback_called = $stop_job_aborted = 0;

        OpenQA::Worker::Jobs::handle_status_upload_finished(1, $job_id, $upload_up_to, $callback2, {});
        is($stop_job_aborted,     0, 'undefined status upload result on final status update is ignored');
        is($upload_images_called, 1, 'image upload attempted');
        is($callback_called,      1, 'callback also in the error case called');

        $upload_images_called = 0;
        OpenQA::Worker::Jobs::handle_status_upload_finished(0, $job_id, $upload_up_to, $callback, {});
        is($stop_job_aborted, 'api-failure', 'failing image upload is considered an API failure');
    };

    subtest 'successful upload' => sub {
        $callback_called      = $stop_job_aborted = $upload_images_called = 0;
        $upload_images_result = 1;

        OpenQA::Worker::Jobs::handle_status_upload_finished(0, $job_id, $upload_up_to, $callback2, {});
        is($upload_images_called, 1, 'image upload attempted');
        is($stop_job_aborted,     0, 'job not aborted');
        is($callback_called,      1, 'callback called');
    };

    subtest 'post upload progress to liveviewhandler' => sub {
        $stop_job_aborted                 = $upload_images_called = $callback_called = 0;
        $is_developer_session_started_res = 1;
        $worker_jobs_mock->unmock('post_upload_progress_to_liveviewhandler');

        my $upload_progress;
        $worker_jobs_mock->mock(
            api_call => sub {
                my ($method, $path, %args) = @_;
                print("api_call done\n");
                is($method,             'post', 'upload progress posted');
                is($args{non_critical}, 1,      'uploading progress to livehandler not considered critical');
                $upload_progress = $args{json};
            });
        OpenQA::Worker::Jobs::handle_status_upload_finished(0, $job_id, $upload_up_to, $callback2, {});
        is($upload_images_called, 1, 'image upload attempted');
        is($stop_job_aborted,     0, 'job not aborted');
        is_deeply(
            $upload_progress,
            {
                outstanding_files           => 0,
                outstanding_images          => 0,
                upload_up_to                => 'some module',
                upload_up_to_current_module => undef,
            },
            'progress uploaded'
        ) or diag explain $upload_progress;

        $stop_job_aborted = $upload_images_called = 0;
        $upload_progress  = undef;
        OpenQA::Worker::Jobs::handle_status_upload_finished(0, $job_id, $upload_up_to, $callback2, {});
        is($upload_images_called, 1,     'image upload attempted');
        is($stop_job_aborted,     0,     'job not aborted');
        is($upload_progress,      undef, 'no upload progress posted if nothing changed');
        is($callback_called,      1,     'callback called');
    };

    $worker_jobs_mock->unmock_all();
};

done_testing();

package FakeTx;
my $singleton;
sub new { $singleton ||= bless({}, shift) }
sub get { my ($self, $id) = @_; return (@{$self->{recv}})[$id]->{json} }
sub send { push(@{+shift()->{recv}}, @_) }
