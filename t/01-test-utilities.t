#!/usr/bin/env perl
# Copyright (C) 2020 SUSE LLC
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

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib";
use OpenQA::Test::TimeLimit '15';
use OpenQA::Test::Utils 'stop_service';
use IPC::Run 'start';
use Test::Output 'combined_like';
use Test::MockModule;

subtest 'warnings in sub processes are fatal test failures' => sub {
    my $test_utils_mock        = Test::MockModule->new('OpenQA::Test::Utils');
    my $test_would_have_failed = 0;
    $test_utils_mock->redefine(
        _fail_and_exit => sub {
            like(shift, qr/sub process test-process terminated with exit code \d+/, 'message of test failure');
            isnt(shift, 0, 'exit code of test failure is non-zero');
            $test_would_have_failed = 1;
        });
    combined_like {
        # start a sub process like the test helper do and simulate a Perl warning
        OpenQA::Test::Utils::_setup_sigchld_handler 'test-process', start sub {
            OpenQA::Test::Utils::_setup_sub_process 'test-process';
            '' . undef;    # provoke Perl warning "Use of uninitialized value in concatenation …"
        };
        # wait at most 5 seconds (the sleep is supposed to be interrupted by SIGCHLD)
        sleep 5;
    }
    qr/Stopping test-process process because a Perl warning occurred: Use of uninitialized value in concatenation/,
      'warning logged';
    ok($test_would_have_failed, 'test would have failed');

    # stop the process via stop_service (previously tested handling of SIGCHLD/warnings does not interfere)
    $test_would_have_failed = 0;
    my $ipc_run_harness = OpenQA::Test::Utils::_setup_sigchld_handler 'test-process', start sub {
        OpenQA::Test::Utils::_setup_sub_process 'test-process';
        # wait at most 5 seconds (supposed to be interrupted by SIGTERM)
        sleep 5;
        exit -1;
    };
    stop_service($ipc_run_harness);
    is($test_would_have_failed, 0, 'manual termination via stop_service does not trigger _fail_and_exit');
};

done_testing();
