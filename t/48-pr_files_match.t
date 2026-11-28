#!/usr/bin/perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;
use Test::Warnings ':report_warnings';
use Mojo::File qw(path tempdir);

my $tool = path(__FILE__)->realpath->dirname->dirname->child('tools', 'pr_files_match');
my $bin = tempdir(CLEANUP => 1);
my $argv = $bin->child('argv');
my $stderr = $bin->child('stderr');
$bin->child('gh')->spew(<<~'SCRIPT')->chmod(0755);
    #!/bin/bash
    printf '%s\n' "$@" > "${GH_ARGV:?}"
    printf '%s' "${GH_FILES:-}"
    exit "${GH_EXIT:-0}"
    SCRIPT

local $ENV{PATH} = join ':', $bin, $ENV{PATH};
local $ENV{GITHUB_REPOSITORY} = 'os-autoinst/openQA';
local $ENV{GH_ARGV} = "$argv";

sub run_tool ($pr, $pattern) {
    my $stdout = qx{$tool "$pr" "$pattern" 2>$stderr};
    my $status = $? >> 8;
    chomp $stdout;
    return {stdout => $stdout, status => $status, stderr => $stderr->slurp};
}

is run_tool('', '^container/')->{stdout}, 'true', 'absent pull request number makes the check pass';

local $ENV{GH_FILES} = "container/webui/Dockerfile\nMakefile\n";
is run_tool('1', '^container/')->{stdout}, 'true', 'changed container file makes the check pass';
is run_tool('1', '^Makefile$')->{stdout}, 'true', 'changed Makefile makes the check pass';
is run_tool('1', '^tools/retry$')->{stdout}, 'false', 'unrelated change makes the check not relevant';

local $ENV{GH_FILES} = "tools/retry\n";
is run_tool('7', '^tools/retry$')->{stdout}, 'true', 'changed helper script makes the check pass';
like $argv->slurp, qr{pulls/7/files}, 'file list is read from the pulls endpoint';
like $argv->slurp, qr{--paginate}, 'file list is paginated';

my $invalid = run_tool('1', '^container/(');
is $invalid->{status}, 2, 'invalid pattern fails instead of reporting irrelevance';
like $invalid->{stderr}, qr{Invalid pattern}, 'invalid pattern is named';

{
    local $ENV{GH_EXIT} = 1;
    my $unreadable = run_tool('1', '^container/');
    is $unreadable->{stdout}, 'true', 'unreadable pull request makes the check pass';
    like $unreadable->{stderr}, qr{Could not list files of pull request 1},
      'unreadable pull request names the pull request';
}

sub relevance_pattern ($workflow) {
    my ($pattern) = path('.github/workflows', $workflow)->slurp =~ /^\s*RELEVANT: (\S+)$/m;
    return $pattern;
}

my %relevant_files = (
    'compose.yml' => [
        qw(container/webui/Dockerfile tools/test_containers_compose tools/retry tools/pr_files_match Makefile),
        '.github/workflows/compose.yml'
    ],
    'check-helm-chart.yml' => [
        qw(container/helm/openqa/values.yaml tools/test_helm_chart tools/retry tools/pr_files_match Makefile),
        '.github/workflows/check-helm-chart.yml'
    ],
);

for my $workflow (sort keys %relevant_files) {
    my $pattern = relevance_pattern($workflow);
    for my $file (@{$relevant_files{$workflow}}) {
        local $ENV{GH_FILES} = "$file\n";
        is run_tool('1', $pattern)->{stdout}, 'true', "$workflow considers $file relevant";
    }
    local $ENV{GH_FILES} = "lib/OpenQA/Foo.pm\n";
    is run_tool('1', $pattern)->{stdout}, 'false', "$workflow ignores an unrelated change";
}

my %gated_steps = ('compose.yml' => 1, 'check-helm-chart.yml' => 4);
for my $workflow (sort keys %gated_steps) {
    my $yaml = path('.github/workflows', $workflow)->slurp;
    is scalar(() = $yaml =~ /^\s+if: steps\.relevant\.outputs\.\w+ == 'true'$/mg), $gated_steps{$workflow},
      "$workflow gates every expensive step on the relevance output";
    like $yaml, qr{pull-requests: read}, "$workflow may read the pull request";
    like $yaml, qr{^  push:\n    branches: \[master\]$}m, "$workflow does not build on unrelated pushes";
}

done_testing;
