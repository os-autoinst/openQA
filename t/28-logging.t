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
use OpenQA::Utils qw(log_error log_warning log_fatal log_info log_debug);
use OpenQA::FakeApp;
use File::Path qw(make_path remove_tree);
use Sys::Hostname;
use File::Spec::Functions 'catfile';

my $re = qr/\[.*?\] \[worker:(.*)\] (.*) message/;

subtest 'Logging to stdout' => sub {
    delete $ENV{OPENQA_WORKER_LOGDIR};

    # Capture STDOUT:
    # 1- dups the current STDOUT to $oldSTDOUT. This is used to restore the STDOUT later
    # 2- Closes the current STDOUT
    # 2- Links the STDOUT to the variable
    open(my $oldSTDOUT, ">&", STDOUT) or die "Can't preserve STDOUT\n$!\n";
    close STDOUT;
    my $output;
    open STDOUT, '>', \$output;
    ### Testing code here ###

    my $app = OpenQA::FakeApp->new(
        mode     => 'production',
        log_name => 'worker',
        instance => 1,
        log_dir  => undef,
        level    => 'debug'
    );

    $app->setup_log();
    $OpenQA::Utils::app = $app;
    log_debug('debug message');
    log_error('error message');
    log_info('info message');

    ### End of the Testing code ###
    # Close the capture (current stdout) and restore STDOUT (by dupping the old STDOUT);
    close STDOUT;
    open(STDOUT, '>&', $oldSTDOUT) or die "Can't dup \$oldSTDOUT: $!";

    # Tests
    my @matches = ($output =~ m/$re/gm);
    ok(@matches / 2 == 3, 'Worker log matches');
    for (my $i = 0; $i < @matches; $i += 2) {
        ok($matches[$i] eq $matches[$i + 1], "OK $matches[$i]");
    }
};

subtest 'Logging to file' => sub {
    $ENV{OPENQA_WORKER_LOGDIR} = tempdir;
    make_path $ENV{OPENQA_WORKER_LOGDIR};

    my $app = OpenQA::FakeApp->new(
        mode     => 'production',
        log_name => 'worker',
        instance => 1,
        log_dir  => $ENV{OPENQA_WORKER_LOGDIR},
        level    => 'debug'
    );
    my $output_logfile = catfile($ENV{OPENQA_WORKER_LOGDIR}, hostname() . '-1.log');

    $app->setup_log();
    $OpenQA::Utils::app = $app;
    log_debug('debug message');
    log_error('error message');
    log_info('info message');

    # Tests
    my @matches = (Mojo::File->new($output_logfile)->slurp =~ m/$re/gm);
    ok(@matches / 2 == 3, 'Worker log matches');
    for (my $i = 0; $i < @matches; $i += 2) {
        ok($matches[$i] eq $matches[$i + 1], "OK $matches[$i]");
    }

    # clear the system
    remove_tree $ENV{OPENQA_WORKER_LOGDIR};
    delete $ENV{OPENQA_WORKER_LOGDIR};
};

subtest 'log fatal to stderr' => sub {
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

    my $app = OpenQA::FakeApp->new(
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
    make_path $ENV{OPENQA_WORKER_LOGDIR};

    my $output_logfile = catfile($ENV{OPENQA_WORKER_LOGDIR}, hostname() . '-1.log');

    my @loglevels    = qw(debug info warn error fatal);
    my $deathcounter = 0;
    my $counter      = @loglevels;
    for (@loglevels) {
        my $app = OpenQA::FakeApp->new(
            mode     => 'production',
            log_name => 'worker',
            instance => 1,
            log_dir  => $ENV{OPENQA_WORKER_LOGDIR},
            level    => $_
        );

        $app->setup_log();
        $OpenQA::Utils::app = $app;

        log_debug('debug message');
        log_info('info message');
        log_warning('warn message');
        log_error('error message');

        my $exception = 0;
        eval { log_fatal('fatal message'); };

        $deathcounter++ if $@;

        my %matches = map { $_ => 1 } (Mojo::File->new($output_logfile)->slurp =~ m/$re/gm);
        ok(keys(%matches) == $counter--, "Worker log level $_ entry");
        truncate $output_logfile, 0;
    }
    ok($deathcounter == @loglevels, "Worker dies when logs fatal");

    # clear the system
    remove_tree $ENV{OPENQA_WORKER_LOGDIR};
    delete $ENV{OPENQA_WORKER_LOGDIR};
};

done_testing;
