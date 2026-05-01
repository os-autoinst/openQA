# Copyright 2019-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
# We need :no_end_test here because otherwise it would output a no warnings
# test for each of the modules, but with the same test number
use Test::Warnings qw(:no_end_test :report_warnings);
use Test::Compile;
use File::Which;
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '400';


my $SKIP = [
    # skip test module which would require test API from os-autoinst to be present
    't/data/openqa/share/tests/opensuse/tests/installation/installer_timezone.pm',
    # Skip data files which are supposed to resemble generated output which has no 'use' statements
    't/data/40-templates.pl',
    't/data/40-templates-jgs.pl',
    't/data/40-templates-more.pl',
    't/data/openqa-trigger-from-obs/Proj2::appliances/.api_package',
    't/data/openqa-trigger-from-obs/Proj2::appliances/.dirty_status',
    't/data/openqa-trigger-from-obs/Proj3::standard/empty.txt',
];

my $test = Test::Compile->new();
my @files;

# Prevent any non-tracked files or files within .git (e.g. in.git/rr-cache) to
# interfer
if (-d '.git' and which('git')) {
    my $root = qx{git rev-parse --show-toplevel};
    chomp $root;
    $root .= '/';
    my @all_git_files = qx{git ls-files};
    chomp @all_git_files;
    my %skip = map { $_ => undef } @$SKIP;
    @files = map { $root . $_ }
      grep { !-l $_ && !exists $skip{$_} && $_ !~ /^(?:external|t|xt)\// } @all_git_files;    # Exclude files to skip
}
else {
    @files = ($test->all_pm_files('lib'), $test->all_pl_files('script'));
    my %skip = map { $_ => undef } @$SKIP;
    @files = grep { my $f = s{^\./}{}r; !exists $skip{$f} && $f !~ /^(?:external|t|xt)\// } @files;
}

# Only check perl files and skip test scripts (already executed)
@files = grep { /\.(?:pm|pl|t)$/ } @files;

plan tests => scalar @files;

foreach my $file (@files) {
    my $ok = $file =~ /\.pm$/ ? $test->pm_file_compiles($file) : $test->pl_file_compiles($file);
    ok $ok, "Syntax check $file";
}
