#!/usr/bin/env perl
# Copyright 2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings ':report_warnings';

use FindBin '$Bin';
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '120';
use IPC::Run qw(run timeout);

plan skip_all => 'set HEAVY=1 to execute (takes longer)' unless $ENV{HEAVY};

my %allowed_types = (
    'text/x-perl' => 1,
    'text/x-python' => 1,
    'text/x-shellscript' => 1,
);

# Could also use MIME::Types, would be new dependency
chomp(my @types = qx{cd $Bin/../script; for i in *; do echo \$i; file --mime-type --brief \$i; done});

my %types = @types;
for my $key (keys %types) {
    delete $types{$key} unless $allowed_types{$types{$key}};
}

my $script_timeout = OpenQA::Test::TimeLimit::scale_timeout(6);

sub test_script {
    my ($script, $args, $expected_success, $msg) = @_;
    my ($out, $err);
    # Mojolicious does not execute some code when it's run in test mode
    local $ENV{HARNESS_ACTIVE} = 0;
    my $success = eval { run ["$Bin/../script/$script", @$args], \undef, \$out, \$out, timeout($script_timeout) };
    if ($@ =~ /timeout/) {
        fail "$msg (timed out after ${script_timeout}s)";
        return;
    }
    is !!$success, !!$expected_success, $msg or diag "Output: $out";
}

for my $script (sort keys %types) {
    test_script($script, ['--help'], 1, "Calling '$script --help' returns exit code 0");

    next if $script eq 'openqa-worker-cacheservice-minion';    # unfortunately ignores invalid arguments

    test_script($script, [qw(invalid-command --invalid-flag)],
        0, "Calling '$script invalid-command --invalid-flag' returns non-zero exit code");
}

done_testing;
