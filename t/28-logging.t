#!/usr/bin/env perl -w

# Copyright (C) 2014-2017 SUSE LLC
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
BEGIN {
    unshift @INC, 'lib';
}
use Test::More;
use Mojo::File qw(tempdir tempfile);
use OpenQA::Utils qw(log_error log_warning log_fatal log_info log_debug add_log_channel remove_log_channel);
use OpenQA::Setup;
use File::Path qw(make_path remove_tree);
use Sys::Hostname;
use File::Spec::Functions 'catfile';

my $reFile    = qr/\[.*?\] \[(.*?)\] (?:\[pid:\d+\]\s)?(.*?) message/;
my $reStdOut  = qr/(?:.*?)\[(.*?)\] (?:\[pid:\d+\]\s)?(.*?) message/;
my $reChannel = qr/\[.*?\] \[(.*?)\] (?:\[pid:\d+\]\s)?(.*?) message/;

subtest 'load correct configs' => sub {
    local $ENV{OPENQA_CONFIG} = 't/data/logging/';
    my $app = OpenQA::Setup->new(
        mode     => 'production',
        log_name => 'worker',
        instance => 1,
        log_dir  => undef,
        level    => 'debug'
    );

    OpenQA::Setup::read_config($app);
    is($app->level,                    'debug');
    is($app->mode,                     'production');
    is($app->config->{logging}{level}, 'warning');
    is($app->log->level,               'info');
    OpenQA::Setup::setup_log($app);
    is($app->level,      'debug');
    is($app->log->level, 'debug');

    $app = OpenQA::Setup->new();
    OpenQA::Setup::read_config($app);
    is($app->level,                    undef);
    is($app->mode,                     'production');
    is($app->config->{logging}{level}, 'warning');
    is($app->log->level,               'info');
    OpenQA::Setup::setup_log($app);
    is($app->level,      undef);
    is($app->log->level, 'warning');

};

subtest 'Logging to stdout' => sub {
    local $ENV{OPENQA_WORKER_LOGDIR};
    local $ENV{OPENQA_LOGFILE};
    # Capture STDOUT:
    # 1- dups the current STDOUT to $oldSTDOUT. This is used to restore the STDOUT later
    # 2- Closes the current STDOUT
    # 2- Links the STDOUT to the variable
    open(my $oldSTDOUT, ">&", STDOUT) or die "Can't preserve STDOUT\n$!\n";
    close STDOUT;
    my $output;
    open STDOUT, '>', \$output;
    ### Testing code here ###

    my $app = OpenQA::Setup->new(
        mode     => 'production',
        log_name => 'worker',
        instance => 1,
        log_dir  => undef,
        level    => 'debug'
    );

    $app->setup_log();

    log_debug('debug message');
    log_error('error message');
    log_info('info message');

    ### End of the Testing code ###
    # Close the capture (current stdout) and restore STDOUT (by dupping the old STDOUT);
    close STDOUT;
    open(STDOUT, '>&', $oldSTDOUT) or die "Can't dup \$oldSTDOUT: $!";
    my @matches = ($output =~ m/$reStdOut/gm);

    like $output, qr/$$/, 'Pid is printed in debug mode';
    ok(@matches / 2 == 3, 'Worker log matches');
    for (my $i = 0; $i < @matches; $i += 2) {
        ok($matches[$i] eq $matches[$i + 1], "OK $matches[$i]");
    }
};

subtest 'Logging to file' => sub {
    delete $ENV{OPENQA_LOGFILE};
    $ENV{OPENQA_WORKER_LOGDIR} = tempdir;
    make_path $ENV{OPENQA_WORKER_LOGDIR};

    my $app = OpenQA::Setup->new(
        mode     => 'production',
        log_name => 'worker',
        instance => 1,
        log_dir  => $ENV{OPENQA_WORKER_LOGDIR},
        level    => 'debug'
    );
    my $output_logfile = catfile($ENV{OPENQA_WORKER_LOGDIR}, hostname() . '-1.log');
    $app->setup_log();
    log_debug('debug message');
    log_error('error message');
    log_info('info message');

    # Tests
    my @matches = (Mojo::File->new($output_logfile)->slurp =~ m/$reFile/gm);
    ok(@matches / 2 == 3, 'Worker log matches');
    for (my $i = 0; $i < @matches; $i += 2) {
        ok($matches[$i] eq $matches[$i + 1], "OK $matches[$i]");
    }

    # clear the system
    remove_tree $ENV{OPENQA_WORKER_LOGDIR};
    delete $ENV{OPENQA_WORKER_LOGDIR};
};

subtest 'log fatal to stderr' => sub {
    delete $ENV{OPENQA_LOGFILE};
    delete $ENV{OPENQA_WORKER_LOGDIR};
    # Capture STDERR:
    # 1- dups the current STDERR to $oldSTDERR. This is used to restore the STDERR later
    # 2- Closes the current STDERR
    # 2- Links the STDERR to the variable
    open(my $oldSTDERR, ">&", STDERR) or die "Can't preserve STDERR\n$!\n";
    close STDERR;
    my $output;
    open STDERR, '>', \$output;
    ### Testing code here ###

    my $app = OpenQA::Setup->new(
        mode     => 'production',
        log_name => 'worker',
        instance => 1,
        log_dir  => undef,
        level    => 'debug'
    );

    $app->setup_log();
    $OpenQA::Utils::app = undef;    # To make sure we don't are setting it in other tests
    eval { log_fatal('fatal message'); };
    my $exception_raised = 0;
    $exception_raised++ if $@;
    ### End of the Testing code ###
    # Close the capture (current stdout) and restore STDOUT (by dupping the old STDOUT);
    close STDERR;
    open(STDERR, '>&', $oldSTDERR) or die "Can't dup \$oldSTDERR: $!";
    ok($exception_raised == 1, 'Fatal raised exception');
    like($output, qr/\[FATAL\] fatal message/, 'OK fatal');

};

subtest 'Checking log level' => sub {
    $ENV{OPENQA_WORKER_LOGDIR} = tempdir;
    delete $ENV{MOJO_LOG_LEVEL};    # The Makefile is overriding this variable
    delete $ENV{OPENQA_LOGFILE};
    make_path $ENV{OPENQA_WORKER_LOGDIR};

    my $output_logfile = catfile($ENV{OPENQA_WORKER_LOGDIR}, hostname() . '-1.log');

    my @loglevels      = qw(debug info warn error fatal);
    my @channels       = qw(channel1 channel2 channel3);
    my $deathcounter   = 0;
    my $counterFile    = @loglevels;
    my $counterChannel = @loglevels;
    for my $level (@loglevels) {
        my $app = OpenQA::Setup->new(
            mode     => 'production',
            log_name => 'worker',
            instance => 1,
            log_dir  => $ENV{OPENQA_WORKER_LOGDIR},
            level    => $level
        );

        $app->setup_log();
        # $OpenQA::Utils::app = $app;

        log_debug('debug message');
        log_info('info message');
        log_warning('warn message');
        log_error('error message');

        eval { log_fatal('fatal message'); };

        $deathcounter++ if $@;

        my %matches = map { $_ => 1 } (Mojo::File->new($output_logfile)->slurp =~ m/$reFile/gm);
        ok(keys(%matches) == $counterFile, "Worker log level $level entry");

        for my $channel (@channels) {
            my $logging_test_file = tempfile;

            add_log_channel($channel, path => $logging_test_file, level => $level);
            log_debug("debug message", channels => $channel);
            log_info("info message", channels => $channel);
            log_warning("warn message", channels => $channel);
            log_error("error message", channels => $channel);

            eval { log_fatal('fatal message', channels => $channel); };
            $deathcounter++ if $@;

            %matches = map { $_ => 1 } (Mojo::File->new($logging_test_file)->slurp =~ m/$reChannel/gm);
            ok(keys(%matches) == $counterChannel, "Worker channel log level $level entry");  # TODO
                                                                                             #  use Data::Dumper;
                                                                                             #  print Dumper(\%matches);
                 #  print "counter Channel: $counterChannel";
                 # unlink $logging_test_file;
        }
        $counterChannel--;

        log_debug("debug message", channels => 'no_channel');
        log_info("info message", channels => 'no_channel');
        log_warning("warn message", channels => 'no_channel');
        log_error("error", channels => 'no_channel');

        eval { log_fatal('fatal message', channels => 'no_channel'); };

        $deathcounter++ if $@;

        # print Mojo::File->new($output_logfile)->slurp;

        %matches = map { $_ => ($matches{$_} // 0) + 1 } (Mojo::File->new($output_logfile)->slurp =~ m/$reFile/gm);
        my @vals = grep { $_ != 2 } (values(%matches));
        ok(keys(%matches) == $counterFile--, "Worker no existent channel log level $level entry");
        ok(@vals == 0,                       'Worker no existent channel log level $level entry ');

        truncate $output_logfile, 0;
    }
    ok($deathcounter == (@loglevels * 2 + @channels * @loglevels), "Worker dies when logs fatal");

    # clear the system
    remove_tree $ENV{OPENQA_WORKER_LOGDIR};
    delete $ENV{OPENQA_WORKER_LOGDIR};
};

subtest 'Logging to right place' => sub {
    delete $ENV{OPENQA_LOGFILE};
    $ENV{OPENQA_WORKER_LOGDIR} = tempdir;
    make_path $ENV{OPENQA_WORKER_LOGDIR};

    my $app = OpenQA::Setup->new(
        mode     => 'production',
        log_name => 'worker',
        instance => 1,
        log_dir  => $ENV{OPENQA_WORKER_LOGDIR},
        level    => 'debug'
    );
    my $output_logfile = catfile($ENV{OPENQA_WORKER_LOGDIR}, hostname() . '-1.log');
    $app->setup_log();
    log_debug('debug message');
    log_error('error message');
    log_info('info message');
    ok(-f $output_logfile, 'Log file defined in logdir');

    local $ENV{OPENQA_LOGFILE} = 'test_log_file.log';
    $app = OpenQA::Setup->new(
        mode     => 'production',
        log_name => 'worker',
        instance => 1,
        log_dir  => $ENV{OPENQA_WORKER_LOGDIR},
        level    => 'debug'
    );
    $app->setup_log();
    log_debug('debug message');
    log_error('error message');
    log_info('info message');
    ok(
        -f catfile($ENV{OPENQA_WORKER_LOGDIR}, $ENV{OPENQA_LOGFILE}),
        'Log file created defined in logdir and environment'
    );


    local $ENV{OPENQA_LOGFILE} = catfile($ENV{OPENQA_WORKER_LOGDIR}, 'another_test_log_file.log');
    $app = OpenQA::Setup->new(
        mode     => 'production',
        log_name => 'worker',
        instance => 1,
        level    => 'debug'
    );
    $app->setup_log();
    log_debug('debug message');
    log_error('error message');
    log_info('info message');
    ok(-f $ENV{OPENQA_LOGFILE}, 'Log file created defined in environment');

    # clear the system
    remove_tree $ENV{OPENQA_WORKER_LOGDIR};
    delete $ENV{OPENQA_WORKER_LOGDIR};
};

subtest 'Logs to multiple channels' => sub {
    delete $ENV{OPENQA_LOGFILE};
    $ENV{OPENQA_WORKER_LOGDIR} = tempdir;
    make_path $ENV{OPENQA_WORKER_LOGDIR};

    my $output_logfile  = catfile($ENV{OPENQA_WORKER_LOGDIR}, hostname() . '-1.log');
    my @loglevels       = qw(debug info warn error fatal);
    my @channel_tupples = ([qw/channel1 channel2/], [qw/channel3 channel4/]);
    my $counterChannel  = @loglevels;


    for my $level (@loglevels) {
        my $app = OpenQA::Setup->new(
            mode     => 'production',
            log_name => 'worker',
            instance => 1,
            log_dir  => $ENV{OPENQA_WORKER_LOGDIR},
            level    => $level
        );
        $app->setup_log();

        for my $channel_tupple (@channel_tupples) {
            my $logging_test_file1 = tempfile;
            my $logging_test_file2 = tempfile;

            add_log_channel($channel_tupple->[0], path => $logging_test_file1, level => $level);
            add_log_channel($channel_tupple->[1], path => $logging_test_file2, level => $level);

            log_debug("debug message", channels => $channel_tupple, standard => 1);
            log_info("info message", channels => $channel_tupple, standard => 1);
            log_warning("warn message", channels => $channel_tupple, standard => 1);
            log_error("error message", channels => $channel_tupple, standard => 1);

            eval { log_fatal('fatal message', channels => $channel_tupple, standard => 1); };

            my %matches = map { $_ => 1 } (Mojo::File->new($logging_test_file1)->slurp =~ m/$reChannel/gm);
            ok(keys(%matches) == $counterChannel,
                "Worker multiple channel $channel_tupple->[0] log level $level entry");

            %matches = map { $_ => 1 } (Mojo::File->new($logging_test_file2)->slurp =~ m/$reChannel/gm);
            ok(keys(%matches) == $counterChannel,
                "Worker multiple channel $channel_tupple->[1] log level $level entry");
            %matches = map { $_ => 1 } (Mojo::File->new($output_logfile)->slurp =~ m/$reFile/gm);
            ok(keys(%matches) == $counterChannel, "Worker multiple channel Default log level $level entry");
            truncate $output_logfile, 0;
        }
        $counterChannel--;
    }

    # clear the system
    remove_tree $ENV{OPENQA_WORKER_LOGDIR};
    delete $ENV{OPENQA_WORKER_LOGDIR};

};

subtest 'Logs to bogus channels' => sub {
    delete $ENV{OPENQA_LOGFILE};
    $ENV{OPENQA_WORKER_LOGDIR} = tempdir;
    make_path $ENV{OPENQA_WORKER_LOGDIR};

    my $output_logfile  = catfile($ENV{OPENQA_WORKER_LOGDIR}, hostname() . '-1.log');
    my @loglevels       = qw(debug info warn error fatal);
    my @channel_tupples = ([qw/channel1 channel2/], [qw/channel3 channel4/]);
    my $counterChannel  = @loglevels;

    for my $level (@loglevels) {
        my $app = OpenQA::Setup->new(
            mode     => 'production',
            log_name => 'worker',
            instance => 1,
            log_dir  => $ENV{OPENQA_WORKER_LOGDIR},
            level    => $level
        );
        $app->setup_log();

        for my $channel_tupple (@channel_tupples) {
            my $logging_test_file1 = tempfile;
            my $logging_test_file2 = tempfile;

            add_log_channel($channel_tupple->[0], path => $logging_test_file1, level => $level);
            add_log_channel($channel_tupple->[1], path => $logging_test_file2, level => $level);

            log_debug("debug message", channels => ['test', 'test1']);
            log_info("info message", channels => ['test', 'test1']);
            log_warning("warn message", channels => ['test', 'test1']);
            log_error("error message", channels => ['test', 'test1']);

            eval { log_fatal('fatal message', channels => ['test', 'test1']); };

            my %matches = map { $_ => 1 } (Mojo::File->new($logging_test_file1)->slurp =~ m/$reChannel/gm);
            ok(keys(%matches) == 0, "Worker multiple channel $channel_tupple->[0] log level $level entry");

            %matches = map { $_ => 1 } (Mojo::File->new($logging_test_file2)->slurp =~ m/$reChannel/gm);
            ok(keys(%matches) == 0, "Worker multiple channel $channel_tupple->[1] log level $level entry");

            %matches = map { $_ => 1 } (Mojo::File->new($output_logfile)->slurp =~ m/$reFile/gm);
            ok(keys(%matches) == $counterChannel, "Worker multiple channel Default log level $level entry");
            truncate $output_logfile, 0;

        }
        $counterChannel--;
    }

    # clear the system
    remove_tree $ENV{OPENQA_WORKER_LOGDIR};
    delete $ENV{OPENQA_WORKER_LOGDIR};

};


subtest 'Logs to defaults channels' => sub {
    delete $ENV{OPENQA_LOGFILE};
    $ENV{OPENQA_WORKER_LOGDIR} = tempdir;
    make_path $ENV{OPENQA_WORKER_LOGDIR};

    my $output_logfile = catfile($ENV{OPENQA_WORKER_LOGDIR}, hostname() . '-1.log');
    my @loglevels      = qw(debug info warn error fatal);
    my $counterChannel = @loglevels;


    for my $level (@loglevels) {
        my $app = OpenQA::Setup->new(
            mode     => 'production',
            log_name => 'worker',
            instance => 1,
            log_dir  => $ENV{OPENQA_WORKER_LOGDIR},
            level    => $level
        );
        $app->setup_log();

        my $logging_test_file1 = tempfile;
        my $logging_test_file2 = tempfile;

        add_log_channel('channel 1', path => $logging_test_file1, level => $level, default => 'set');
        add_log_channel('channel 2', path => $logging_test_file2, level => $level);

        log_debug("debug message");
        log_info("info message");
        log_warning("warn message");
        log_error("error message");

        eval { log_fatal('fatal message'); };

        %matches = map { $_ => 1 } (Mojo::File->new($logging_test_file1)->slurp =~ m/$reChannel/gm);
        ok(keys(%matches) == $counterChannel, "Worker default channel 1 log level $level entry");

        %matches = map { $_ => 1 } (Mojo::File->new($logging_test_file2)->slurp =~ m/$reChannel/gm);
        ok(keys(%matches) == 0, "Worker not default channel 2 log level $level entry");

        %matches = map { $_ => 1 } (Mojo::File->new($output_logfile)->slurp =~ m/$reFile/gm);
        ok(keys(%matches) == 0, "Worker not default channels log level $level entry");

        truncate $logging_test_file1, 0;
        truncate $logging_test_file2, 0;



        add_log_channel('channel 2', path => $logging_test_file2, level => $level, default => 'append');

        log_debug("debug message");
        log_info("info message");
        log_warning("warn message");
        log_error("error message");

        eval { log_fatal('fatal message'); };

        %matches = map { $_ => 1 } (Mojo::File->new($logging_test_file1)->slurp =~ m/$reChannel/gm);
        ok(keys(%matches) == $counterChannel, "Worker default channel 1 log level $level entry");

        %matches = map { $_ => 1 } (Mojo::File->new($logging_test_file2)->slurp =~ m/$reChannel/gm);
        ok(keys(%matches) == $counterChannel, "Worker append to default channel 2 log level $level entry");

        %matches = map { $_ => 1 } (Mojo::File->new($output_logfile)->slurp =~ m/$reFile/gm);
        ok(keys(%matches) == 0, "Worker not default channels log level $level entry");


        remove_log_channel('channel 1');
        truncate $logging_test_file1, 0;
        truncate $logging_test_file2, 0;

        log_debug("debug message");
        log_info("info message");
        log_warning("warn message");
        log_error("error message");

        eval { log_fatal('fatal message'); };

        %matches = map { $_ => 1 } (Mojo::File->new($logging_test_file1)->slurp =~ m/$reChannel/gm);
        ok(keys(%matches) == 0, "Worker default channel 1 log level $level entry");

        %matches = map { $_ => 1 } (Mojo::File->new($logging_test_file2)->slurp =~ m/$reChannel/gm);
        ok(keys(%matches) == $counterChannel, "Worker append to default channel 2 log level $level entry");

        %matches = map { $_ => 1 } (Mojo::File->new($output_logfile)->slurp =~ m/$reFile/gm);
        ok(keys(%matches) == 0, "Worker not default channels log level $level entry");


        remove_log_channel('channel 2');
        truncate $logging_test_file1, 0;
        truncate $logging_test_file2, 0;

        log_debug("debug message");
        log_info("info message");
        log_warning("warn message");
        log_error("error message");

        eval { log_fatal('fatal message'); };

        %matches = map { $_ => 1 } (Mojo::File->new($logging_test_file1)->slurp =~ m/$reChannel/gm);
        ok(keys(%matches) == 0, "Worker default channel 1 log level $level entry");

        %matches = map { $_ => 1 } (Mojo::File->new($logging_test_file2)->slurp =~ m/$reChannel/gm);
        ok(keys(%matches) == 0, "Worker append to default channel 2 log level $level entry");

        %matches = map { $_ => 1 } (Mojo::File->new($output_logfile)->slurp =~ m/$reFile/gm);
        ok(keys(%matches) == $counterChannel, "Worker not default channels log level $level entry");


        truncate $output_logfile, 0;


        $counterChannel--;
    }

    # clear the system
    remove_tree $ENV{OPENQA_WORKER_LOGDIR};
    delete $ENV{OPENQA_WORKER_LOGDIR};

};

done_testing;
