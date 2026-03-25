#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use experimental 'signatures';
# See xt/01-comple-check-all.t for ":no_end_test" here
use Test::Warnings qw(:no_end_test :report_warnings);
use FindBin '$Bin';
use File::Spec;

sub extra_include_paths (@extra_paths) {
    my @paths = map { ("$Bin/../$_", "$Bin/../external/os-autoinst-common/$_") } @extra_paths;
    return grep { -e $_ } map { File::Spec->rel2abs($_) } @paths;
}

BEGIN {
    unshift @INC, extra_include_paths('lib', 'lib/perlcritic');
}
use OpenQA::Test::TimeLimit '90';

use Test::Perl::Critic (-profile => '.perlcriticrc');
my $env_glob = $ENV{PERLCRITIC_GLOB};
my @paths = $env_glob
  ? map { glob($_) } split(/[:;]/, $env_glob)
  : (qw(lib xt OpenQA backend consoles container script tools),
    glob('*.pm'),
    grep { !/t\/(data|fake)\// } glob 't/*.t t/*.pm t/*/*.t t/*/*.pm');
Test::Perl::Critic::all_critic_ok(grep { -e $_ } @paths);
