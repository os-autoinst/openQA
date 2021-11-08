#!/usr/bin/env perl
# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings ':report_warnings';
use Time::HiRes 'gettimeofday';
use Mojo::File qw(tempdir tempfile);
use OpenQA::App;
use OpenQA::Setup;
use OpenQA::Log
  qw(log_error log_warning log_fatal log_info log_debug log_trace add_log_channel remove_log_channel log_format_callback get_channel_handle setup_log);
use OpenQA::Worker::App;
use File::Path qw(make_path remove_tree);
use Test::MockModule qw(strict);
use Test::Output qw(stdout_like stderr_like stdout_from stderr_from);
use Sys::Hostname;
use File::Spec::Functions 'catfile';
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '4';

my $reFile = qr/\[.*?\] \[(.*?)\] (?:\[pid:\d+\]\s)?(.*?) message/;
my $reStdOut = qr/(?:.*?)\[(.*?)\] (?:\[pid:\d+\]\s)?(.*?) message/;
my $reChannel = qr/\[.*?\] \[(.*?)\] (?:\[pid:\d+\]\s)?(.*?) message/;

subtest 'load correct configs' => sub {
    local $ENV{OPENQA_CONFIG} = 't/data/logging/';
    my $app = OpenQA::Worker::App->new(
        mode => 'production',
        log_name => 'worker',
        instance => 1,
        log_dir => undef,
        level => 'debug'
    );

    OpenQA::Setup::read_config($app);
    is($app->level, 'debug');
    is($app->mode, 'production');
    is($app->config->{logging}{level}, 'warning');
    is($app->log->level, 'info');
    setup_log($app, undef, $app->log_dir, $app->level);
    is($app->level, 'debug');
    is($app->log->level, 'debug');

    $app = OpenQA::Worker::App->new();
    OpenQA::Setup::read_config($app);
    is($app->level, undef);
    is($app->mode, 'production');
    is($app->config->{logging}{level}, 'warning');
    is($app->log->level, 'info');
    setup_log($app);
    is($app->level, undef);
    is($app->log->level, 'warning');

};

subtest 'Logging to stdout' => sub {
    local $ENV{OPENQA_WORKER_LOGDIR};
    local $ENV{OPENQA_LOGFILE};
    my $app = OpenQA::Worker::App->new(
        mode => 'production',
        log_name => 'worker',
        instance => 1,
        log_dir => undef,
        level => 'debug'
    );

    setup_log($app, undef, $app->log_dir, $app->level);

    my $output = stdout_from {
        log_trace('trace message');
        log_debug('debug message');
        log_error('error message');
        log_info('info message');
    };
    note $output;
    my @matches = ($output =~ m/$reStdOut/gm);

    like $output, qr/debug message/;
    unlike $output, qr/trace message/;

    like $output, qr/$$/, 'Pid is printed in debug mode';
    is(@matches / 2, 3, 'Worker log matches');
    for (my $i = 0; $i < @matches; $i += 2) {
        like($matches[$i], qr/$matches[$i + 1]/, "OK $matches[$i]");
    }
};

subtest 'Logging to file' => sub {
    delete $ENV{OPENQA_LOGFILE};
    my $tempdir = tempdir;
    local $ENV{OPENQA_WORKER_LOGDIR} = $tempdir;

    my $app = OpenQA::Worker::App->new(
        mode => 'production',
        log_name => 'worker',
        instance => 1,
        log_dir => $ENV{OPENQA_WORKER_LOGDIR},
        level => 'debug'
    );
    my $output_logfile = catfile($ENV{OPENQA_WORKER_LOGDIR}, hostname() . '-1.log');
    setup_log($app, undef, $app->log_dir, $app->level);
    log_debug('debug message');
    log_error('error message');
    log_info('info message');

    # Tests
    my @matches = (Mojo::File->new($output_logfile)->slurp =~ m/$reFile/gm);
    is(@matches / 2, 3, 'Worker log matches');
    for (my $i = 0; $i < @matches; $i += 2) {
        is($matches[$i], $matches[$i + 1], "OK $matches[$i]");
    }
};

subtest 'log fatal to stderr' => sub {
    delete $ENV{OPENQA_LOGFILE};
    delete $ENV{OPENQA_WORKER_LOGDIR};
    my $app = OpenQA::Worker::App->new(
        mode => 'production',
        log_name => 'worker',
        instance => 1,
        log_dir => undef,
        level => 'debug'
    );

    setup_log($app);
    OpenQA::App->set_singleton(undef);    # To make sure we are not setting it in other tests
    my $output = stderr_from {
        eval { log_fatal('fatal message') }
    };
    my $eval_error = $@;
    my $exception_raised = 0;
    $exception_raised++ if $eval_error;
    is($exception_raised, 1, 'Fatal raised exception');
    like($output, qr/\[FATAL\] fatal message/, 'OK fatal');
    like($eval_error, qr{fatal message.*t/28-logging.t});

};

subtest 'Checking log level' => sub {
    my $tempdir = tempdir;
    local $ENV{OPENQA_WORKER_LOGDIR} = $tempdir;
    delete $ENV{MOJO_LOG_LEVEL};    # The Makefile is overriding this variable
    delete $ENV{OPENQA_LOGFILE};

    my $output_logfile = catfile($ENV{OPENQA_WORKER_LOGDIR}, hostname() . '-1.log');

    my @loglevels = qw(trace debug info warn error fatal);
    my @channels = qw(channel1 channel2 channel3);
    my $deathcounter = 0;
    my $counterFile = @loglevels;
    my $counterChannel = @loglevels;
    for my $level (@loglevels) {
        my $app = OpenQA::Worker::App->new(
            mode => 'production',
            log_name => 'worker',
            instance => 1,
            log_dir => $ENV{OPENQA_WORKER_LOGDIR},
            level => $level
        );

        setup_log($app, undef, $app->log_dir, $app->level);

        log_trace('trace message');
        log_debug('debug message');
        log_info('info message');
        log_warning('warn message');
        log_error('error message');

        eval { log_fatal('fatal message'); };

        $deathcounter++ if $@;

        my %matches = map { $_ => 1 } (Mojo::File->new($output_logfile)->slurp =~ m/$reFile/gm);
        is(keys(%matches), $counterFile, "Worker log level $level entry");

        for my $channel (@channels) {
            my $logging_test_file = tempfile;

            add_log_channel($channel, path => $logging_test_file, level => $level);
            log_trace("trace message", channels => $channel);
            log_debug("debug message", channels => $channel);
            log_info("info message", channels => $channel);
            log_warning("warn message", channels => $channel);
            log_error("error message", channels => $channel);

            eval { log_fatal('fatal message', channels => $channel); };
            $deathcounter++ if $@;

            %matches = map { $_ => 1 } (Mojo::File->new($logging_test_file)->slurp =~ m/$reChannel/gm);
            is(keys(%matches), $counterChannel, "Worker channel log level $level entry");
            remove_log_channel($channel);
            is(get_channel_handle($channel), undef, "Channel $channel was removed");
        }
        $counterChannel--;

        log_trace("trace message", channels => 'no_channel');
        log_debug("debug message", channels => 'no_channel');
        log_info("info message", channels => 'no_channel');
        log_warning("warn message", channels => 'no_channel');
        log_error("error", channels => 'no_channel');

        eval { log_fatal('fatal message', channels => 'no_channel'); };

        $deathcounter++ if $@;

        # print Mojo::File->new($output_logfile)->slurp;

        %matches = map { $_ => ($matches{$_} // 0) + 1 } (Mojo::File->new($output_logfile)->slurp =~ m/$reFile/gm);
        my @vals = grep { $_ != 2 } (values(%matches));
        is(keys(%matches), $counterFile--, "Worker no existent channel log level $level entry");
        is(@vals, 0, 'Worker no existent channel log level $level entry ');

        truncate $output_logfile, 0;
    }
    is($deathcounter, (@loglevels * 2 + @channels * @loglevels), "Worker dies when logs fatal");
};

subtest 'Logging to right place' => sub {
    delete $ENV{OPENQA_LOGFILE};
    my $tempdir = tempdir;
    local $ENV{OPENQA_WORKER_LOGDIR} = $tempdir;

    my $app = OpenQA::Worker::App->new(
        mode => 'production',
        log_name => 'worker',
        instance => 1,
        log_dir => $ENV{OPENQA_WORKER_LOGDIR},
        level => 'debug'
    );
    my $output_logfile = catfile($ENV{OPENQA_WORKER_LOGDIR}, hostname() . '-1.log');
    setup_log($app, undef, $app->log_dir, $app->level);
    log_debug('debug message');
    log_error('error message');
    log_info('info message');
    ok(-f $output_logfile, 'Log file defined in logdir');

    local $ENV{OPENQA_LOGFILE} = 'test_log_file.log';
    $app = OpenQA::Worker::App->new(
        mode => 'production',
        log_name => 'worker',
        instance => 1,
        log_dir => $ENV{OPENQA_WORKER_LOGDIR},
        level => 'debug'
    );
    setup_log($app, undef, $app->log_dir, $app->level);
    log_debug('debug message');
    log_error('error message');
    log_info('info message');
    ok(
        -f catfile($ENV{OPENQA_WORKER_LOGDIR}, $ENV{OPENQA_LOGFILE}),
        'Log file created defined in logdir and environment'
    );


    local $ENV{OPENQA_LOGFILE} = catfile($ENV{OPENQA_WORKER_LOGDIR}, 'another_test_log_file.log');
    $app = OpenQA::Worker::App->new(
        mode => 'production',
        log_name => 'worker',
        instance => 1,
        level => 'debug'
    );
    setup_log($app);
    log_debug('debug message');
    log_error('error message');
    log_info('info message');
    ok(-f $ENV{OPENQA_LOGFILE}, 'Log file created defined in environment');
};

subtest 'Logs to multiple channels' => sub {
    delete $ENV{OPENQA_LOGFILE};
    my $tempdir = tempdir;
    local $ENV{OPENQA_WORKER_LOGDIR} = $tempdir;

    my $output_logfile = catfile($ENV{OPENQA_WORKER_LOGDIR}, hostname() . '-1.log');
    my @loglevels = qw(trace debug info warn error fatal);
    my @channel_tupples = ([qw/channel1 channel2/], [qw/channel3 channel4/]);
    my $counterChannel = @loglevels;


    for my $level (@loglevels) {
        my $app = OpenQA::Worker::App->new(
            mode => 'production',
            log_name => 'worker',
            instance => 1,
            log_dir => $ENV{OPENQA_WORKER_LOGDIR},
            level => $level
        );
        setup_log($app, undef, $app->log_dir, $app->level);

        for my $channel_tupple (@channel_tupples) {
            my $logging_test_file1 = tempfile;
            my $logging_test_file2 = tempfile;

            add_log_channel($channel_tupple->[0], path => $logging_test_file1, level => $level);
            add_log_channel($channel_tupple->[1], path => $logging_test_file2, level => $level);

            log_trace("trace message", channels => $channel_tupple, standard => 1);
            log_debug("debug message", channels => $channel_tupple, standard => 1);
            log_info("info message", channels => $channel_tupple, standard => 1);
            log_warning("warn message", channels => $channel_tupple, standard => 1);
            log_error("error message", channels => $channel_tupple, standard => 1);

            eval { log_fatal('fatal message', channels => $channel_tupple, standard => 1); };

            my %matches = map { $_ => 1 } (Mojo::File->new($logging_test_file1)->slurp =~ m/$reChannel/gm);
            is(keys(%matches), $counterChannel, "Worker multiple channel $channel_tupple->[0] log level $level entry");

            %matches = map { $_ => 1 } (Mojo::File->new($logging_test_file2)->slurp =~ m/$reChannel/gm);
            is(keys(%matches), $counterChannel, "Worker multiple channel $channel_tupple->[1] log level $level entry");
            %matches = map { $_ => 1 } (Mojo::File->new($output_logfile)->slurp =~ m/$reFile/gm);
            is(keys(%matches), $counterChannel, "Worker multiple channel Default log level $level entry");
            truncate $output_logfile, 0;
        }
        $counterChannel--;
    }
};

subtest 'Logs to bogus channels' => sub {
    delete $ENV{OPENQA_LOGFILE};
    my $tempdir = tempdir;
    local $ENV{OPENQA_WORKER_LOGDIR} = $tempdir;

    my $output_logfile = catfile($ENV{OPENQA_WORKER_LOGDIR}, hostname() . '-1.log');
    my @loglevels = qw(trace debug info warn error fatal);
    my @channel_tupples = ([qw/channel1 channel2/], [qw/channel3 channel4/]);
    my $counterChannel = @loglevels;

    for my $level (@loglevels) {
        my $app = OpenQA::Worker::App->new(
            mode => 'production',
            log_name => 'worker',
            instance => 1,
            log_dir => $ENV{OPENQA_WORKER_LOGDIR},
            level => $level
        );
        setup_log($app, undef, $app->log_dir, $app->level);

        for my $channel_tupple (@channel_tupples) {
            my $logging_test_file1 = tempfile;
            my $logging_test_file2 = tempfile;

            add_log_channel($channel_tupple->[0], path => $logging_test_file1, level => $level);
            add_log_channel($channel_tupple->[1], path => $logging_test_file2, level => $level);

            log_trace("trace message", channels => ['test', 'test1']);
            log_debug("debug message", channels => ['test', 'test1']);
            log_info("info message", channels => ['test', 'test1']);
            log_warning("warn message", channels => ['test', 'test1']);
            log_error("error message", channels => ['test', 'test1']);

            eval { log_fatal('fatal message', channels => ['test', 'test1']); };

            my %matches = map { $_ => 1 } (Mojo::File->new($logging_test_file1)->slurp =~ m/$reChannel/gm);
            is(keys(%matches), 0, "Worker multiple channel $channel_tupple->[0] log level $level entry");

            %matches = map { $_ => 1 } (Mojo::File->new($logging_test_file2)->slurp =~ m/$reChannel/gm);
            is(keys(%matches), 0, "Worker multiple channel $channel_tupple->[1] log level $level entry");

            %matches = map { $_ => 1 } (Mojo::File->new($output_logfile)->slurp =~ m/$reFile/gm);
            is(keys(%matches), $counterChannel, "Worker multiple channel Default log level $level entry");
            truncate $output_logfile, 0;

        }
        $counterChannel--;
    }
};


subtest 'Logs to default channels' => sub {
    delete $ENV{OPENQA_LOGFILE};
    my $tempdir = tempdir;
    local $ENV{OPENQA_WORKER_LOGDIR} = $tempdir;

    my $output_logfile = catfile($ENV{OPENQA_WORKER_LOGDIR}, hostname() . '-1.log');
    my @loglevels = qw(trace debug info warn error fatal);
    my $counterChannel = @loglevels;


    for my $level (@loglevels) {
        my $app = OpenQA::Worker::App->new(
            mode => 'production',
            log_name => 'worker',
            instance => 1,
            log_dir => $ENV{OPENQA_WORKER_LOGDIR},
            level => $level
        );
        setup_log($app, undef, $app->log_dir, $app->level);

        my $logging_test_file1 = tempfile;
        my $logging_test_file2 = tempfile;

        add_log_channel('channel 1', path => $logging_test_file1, level => $level, default => 'set');
        add_log_channel('channel 2', path => $logging_test_file2, level => $level);

        log_trace("trace message");
        log_debug("debug message");
        log_info("info message");
        log_warning("warn message");
        log_error("error message");

        eval { log_fatal('fatal message'); };

        my %matches = map { $_ => 1 } (Mojo::File->new($logging_test_file1)->slurp =~ m/$reChannel/gm);
        is(keys(%matches), $counterChannel, "Worker default channel 1 log level $level entry");

        %matches = map { $_ => 1 } (Mojo::File->new($logging_test_file2)->slurp =~ m/$reChannel/gm);
        is(keys(%matches), 0, "Worker not default channel 2 log level $level entry");

        %matches = map { $_ => 1 } (Mojo::File->new($output_logfile)->slurp =~ m/$reFile/gm);
        is(keys(%matches), 0, "Worker not default channels log level $level entry");

        truncate $logging_test_file1, 0;
        truncate $logging_test_file2, 0;



        add_log_channel('channel 2', path => $logging_test_file2, level => $level, default => 'append');

        log_trace("trace message");
        log_debug("debug message");
        log_info("info message");
        log_warning("warn message");
        log_error("error message");

        eval { log_fatal('fatal message'); };

        %matches = map { $_ => 1 } (Mojo::File->new($logging_test_file1)->slurp =~ m/$reChannel/gm);
        is(keys(%matches), $counterChannel, "Worker default channel 1 log level $level entry");

        %matches = map { $_ => 1 } (Mojo::File->new($logging_test_file2)->slurp =~ m/$reChannel/gm);
        is(keys(%matches), $counterChannel, "Worker append to default channel 2 log level $level entry");

        %matches = map { $_ => 1 } (Mojo::File->new($output_logfile)->slurp =~ m/$reFile/gm);
        is(keys(%matches), 0, "Worker not default channels log level $level entry");


        remove_log_channel('channel 1');
        truncate $logging_test_file1, 0;
        truncate $logging_test_file2, 0;

        log_trace("trace message");
        log_debug("debug message");
        log_info("info message");
        log_warning("warn message");
        log_error("error message");

        eval { log_fatal('fatal message'); };

        %matches = map { $_ => 1 } (Mojo::File->new($logging_test_file1)->slurp =~ m/$reChannel/gm);
        is(keys(%matches), 0, "Worker default channel 1 log level $level entry");

        %matches = map { $_ => 1 } (Mojo::File->new($logging_test_file2)->slurp =~ m/$reChannel/gm);
        is(keys(%matches), $counterChannel, "Worker append to default channel 2 log level $level entry");

        %matches = map { $_ => 1 } (Mojo::File->new($output_logfile)->slurp =~ m/$reFile/gm);
        is(keys(%matches), 0, "Worker not default channels log level $level entry");


        remove_log_channel('channel 2');
        truncate $logging_test_file1, 0;
        truncate $logging_test_file2, 0;

        log_trace("trace message");
        log_debug("debug message");
        log_info("info message");
        log_warning("warn message");
        log_error("error message");

        eval { log_fatal('fatal message'); };

        %matches = map { $_ => 1 } (Mojo::File->new($logging_test_file1)->slurp =~ m/$reChannel/gm);
        is(keys(%matches), 0, "Worker default channel 1 log level $level entry");

        %matches = map { $_ => 1 } (Mojo::File->new($logging_test_file2)->slurp =~ m/$reChannel/gm);
        is(keys(%matches), 0, "Worker append to default channel 2 log level $level entry");

        %matches = map { $_ => 1 } (Mojo::File->new($output_logfile)->slurp =~ m/$reFile/gm);
        is(keys(%matches), $counterChannel, "Worker not default channels log level $level entry");


        truncate $output_logfile, 0;


        $counterChannel--;
    }
};

subtest 'Fallback to stderr/stdout' => sub {
    delete $ENV{OPENQA_LOGFILE};
    my $tempdir = tempdir;
    local $ENV{OPENQA_WORKER_LOGDIR} = $tempdir;

    # let _log_to_channel_by_name and _log_via_mojo_app fail
    my $utils_mock = Test::MockModule->new('OpenQA::Log');
    my $log_via_channel_tried = 0;
    my $log_via_mojo_app_tried = 0;
    $utils_mock->redefine(
        _log_to_channel_by_name => sub {
            ++$log_via_channel_tried;
            return 0;
        });
    $utils_mock->redefine(
        _log_via_mojo_app => sub {
            ++$log_via_mojo_app_tried;
            return 0;
        });

    # add a channel (which shouldn't be used, though)
    my $logging_test_file1 = tempfile;
    add_log_channel('channel 1', path => $logging_test_file1, level => undef, default => 'set');

    # write some messages which should be printed to stdout/stderr
    stdout_like {
        log_debug('debug message');
        log_info('info message');
    }
    qr/.*debug message.*\n.*info message.*/, 'debug/info written to stdout';
    stderr_like {
        log_warning('warning message');
        log_error('error message');
    }
    qr/.*warning message.*\n.*error message.*/, 'warning/error written to stderr';

    # check whether _log_msg attempted to use all ways to log before falling back
    is($log_via_channel_tried, 4, 'tried to log all four messages via the default channel');
    is($log_via_mojo_app_tried, 4, 'tried to log all four messages via Mojolicious app');
    is(Mojo::File->new($logging_test_file1)->slurp, '', 'nothing written to logfile');

    # check fallback on attempt to log to invalid channel
    $utils_mock->redefine(
        _log_to_channel_by_name => sub {
            ++$log_via_channel_tried;
            return $utils_mock->original('_log_to_channel_by_name')->(@_);
        });
    stderr_like {
        log_error('goes to stderr after all', channels => [qw(foo bar)]);
    }
    qr/.*goes to stderr after all.*/, 'logging to invalid channel ends up on stderr';
    is($log_via_channel_tried, 6, 'tried to log the message via the 2 channels');
    is($log_via_mojo_app_tried, 5, 'tried to log via Mojolicious app');

    # check fallback when logging to channel throws an exception
    $utils_mock->unmock('_log_to_channel_by_name');
    my $log_mock = Test::MockModule->new('Mojo::Log');
    $log_mock->redefine(
        error => sub {
            ++$log_via_channel_tried;
            die 'not enough disk space or whatever';
        });
    stderr_like {
        log_error('goes to stderr after all');
    }
    qr/.*goes to stderr after all.*/, 'logging to invalid channel ends up on stderr';
    is($log_via_channel_tried, 7, 'tried to log via the default channel');
    is($log_via_mojo_app_tried, 6, 'tried to log via Mojolicious app');

    # clear the system
    $utils_mock->unmock_all();
    $log_mock->unmock_all();
    remove_log_channel('channel 1');
};

subtest 'Formatting' => sub {
    my $time = gettimeofday;
    my $hires_mock = Test::MockModule->new('Time::HiRes');
    $hires_mock->redefine(gettimeofday => sub() { $time });
    my @loglevels = qw(debug info warn error fatal);
    for my $level (@loglevels) {
        like log_format_callback(undef, $level, ("test $level")), qr/\[.+\] \[$level\] test $level\n$/,
          "Formatting for $level works";
    }
};

ok get_channel_handle, 'get_channel_handle returns valid handle from app';

done_testing;
