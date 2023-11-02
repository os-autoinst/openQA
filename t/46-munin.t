#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings ':report_warnings';

use FindBin '$Bin';
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '5';
use Test::Output qw( stdout_from );

my $script = "$Bin/../contrib/munin/plugins/minion";
my $url = "file://$Bin/data/46-contrib-minion.html";

require $script;

subtest minion_influx => sub {
    local $ENV{url} = $url;

    my $out = stdout_from {
        local $ENV{category} = 'minion_jobs';
        main::main();
    };
    my $exp_minion_jobs = <<'EOM';
active.value 1
delayed.value 0
failed.value 358
inactive.value 0
total.value 359
EOM
    is $out, $exp_minion_jobs, 'minion_jobs';

    $out = stdout_from {
        local $ENV{category} = 'minion_workers';
        main::main();
    };
    my $exp_minion_workers = <<'EOM';
active.value 0
inactive.value 1
registered.value 1
total.value 2
EOM
    is $out, $exp_minion_workers, 'minion_workers';

    $out = stdout_from {
        local $ENV{category} = 'minion_jobs_hook_rc_failed';
        main::main();
    };
    my $exp_minion_jobs_hook_rc_failed = <<'EOM';
rc_failed_per_5min.value 23
total.value 23
EOM
    is $out, $exp_minion_jobs_hook_rc_failed, 'minion_jobs_hook_rc_failed';

    $out = stdout_from {
        local $ENV{category} = 'minion_jobs_hook_rc_failed';
        local @ARGV = 'config';
        main::main();
    };
    my $exp_minion_jobs_hook_rc_failed_config = <<'EOM';
graph_title hook failed - see openqa-gru service logs for details
graph_args --base 1000 -l 0
graph_category minion
graph_order rc_failed_per_5min
graph_vlabel minion_jobs_hook_rc_failed
rc_failed_per_5min.label rc_failed_per_5min
rc_failed_per_5min.draw LINE
rc_failed_per_5min.warning 0.5
rc_failed_per_5min.critical 2
total.label Total
total.graph no
EOM
    is $out, $exp_minion_jobs_hook_rc_failed_config, 'minion_jobs_hook_rc_failed config';
};

done_testing;
