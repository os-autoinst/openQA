#!/usr/bin/env perl
# Copyright 2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use experimental 'signatures';
use Test::Warnings ':report_warnings';
use Test::MockModule;

use FindBin '$Bin';
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '120';
use IPC::Run qw(run timeout);

plan skip_all => 'set HEAVY=1 to execute (takes longer)' unless $ENV{HEAVY};

my %allowed_types = (
    'text/x-perl' => 1,
    'text/x-python' => 1,
    'text/x-script.python' => 1,
    'text/x-shellscript' => 1,
);

# Could also use MIME::Types, would be new dependency
chomp(my @types = qx{cd $Bin/../script; for i in *; do echo \$i; file --mime-type --brief \$i; done});

my %types = @types;
for my $key (keys %types) {
    delete $types{$key} unless $allowed_types{$types{$key}};
}

my $script_timeout = OpenQA::Test::TimeLimit::scale_timeout(6);

sub run_script ($script, $args) {
    my $out;
    # Mojolicious does not execute some code when it's run in test mode
    local $ENV{HARNESS_ACTIVE} = 0;
    my $success = eval { run ["$Bin/../script/$script", @$args], \undef, \$out, \$out, timeout($script_timeout) };
    my $is_timeout = $@ =~ /timeout/ ? 1 : 0;
    return ($success, $out, $is_timeout);
}

for my $script (sort keys %types) {
    my ($success, $out, $timeout) = run_script($script, ['--help']);
    ok $success && !$timeout, "Calling '$script --help' returns exit code 0" or diag "Output: $out";

    next if $script eq 'openqa-worker-cacheservice-minion';    # unfortunately ignores invalid arguments

    ($success, $out, $timeout) = run_script($script, [qw(invalid-command --invalid-flag)]);
    ok !$success && !$timeout, "Calling '$script invalid-command --invalid-flag' returns non-zero exit code"
      or diag "Output: $out";
}

subtest 'YAML validation' => sub {
    my $script = 'openqa-validate-yaml';
    my $job_templates = "$Bin/data/job-templates";
    my ($success, $out, $is_timeout) = run_script $script, ['--validate-schema', "$job_templates/openqa.yaml"];
    ok $success && !$is_timeout, 'validation passed';
    like $out, qr/Validating schema/, 'schema validated as well';
    like $out, qr/openqa.yaml - valid/, 'YAML considered valid';
    ($success, $out, $is_timeout) = run_script $script, ["$job_templates/openqa-invalid.yaml"];
    ok !$success, 'validation failed';
    like $out, qr/not allowed.*invalid.*failed/s, 'YAML considered invalid';
    $out = qx{cat '$job_templates/openqa-invalid.yaml' | '$Bin/../script/$script' - 2>&1};
    like $out, qr/not allowed.*invalid.*failed/s, 'can read YAML from stdin' or always_explain "$script: $!";
};

# cover timeout handling in run_script
{
    my $run_mock = Test::MockModule->new('main', no_auto => 1);
    $run_mock->redefine(run => sub { die 'timeout' });
    my (undef, undef, $timeout) = run_script('client', ['--help']);
    ok $timeout, 'Timeout is correctly detected';
}

done_testing;
