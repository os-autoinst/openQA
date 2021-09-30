# Copyright 2019-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Test::Warnings ':report_warnings';
use Test::Output;
use OpenQA::Test::TimeLimit '20';
use OpenQA::Test::Utils qw(run_cmd test_cmd);


# prevent all network access to stay local
my $cmd = 'unshare -r -n script/openqa-clone-custom-git-refspec';

sub run_once { run_cmd($cmd, @_) }

sub test_once {
    # Report failure at the callsite instead of the test function
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    test_cmd($cmd, @_);
}

# instruct openqa-clone-custom-git-refspec to use dry-run modes for all calls
$ENV{dry_run} = 'echo';

my $ret;
test_once '', qr/Need.*parameter/, 'hint shown for mandatory parameter missing', 1,
  'openqa-clone-custom-git-refspec needs parameters';
test_once '--help', qr/Usage:/, 'help text shown', 0, 'help screen is regarded as success';
test_once '--invalid-arg', qr/Usage:/, 'invalid args also yield help', 1, 'help screen but no success recorded';
my $args = 'https://github.com/user/repo/pull/9128 https://openqa.opensuse.org/tests/1234';
isnt run_once($args), 0, 'without network we fail (without error)';
# mock any external access with all arguments
$ENV{curl_github} = qq{echo -e '{"head": {"label": "user:my/branch"}, "body": "Lorem ipsum"}'; true};
$ENV{curl_openqa}
  = qq{echo -e '{"TEST": "my_test", "CASEDIR": "/my/case/dir", "PRODUCTDIR": "/my/case/dir/product", "NEEDLES_DIR": "/my/case/dir/product/needles"}'; true};
my $clone_job = 'openqa-clone-job --skip-chained-deps --within-instance https://openqa.opensuse.org ';
my $dirs
  = 'CASEDIR=https://github.com/user/repo.git#my/branch PRODUCTDIR=repo/product NEEDLES_DIR=/my/case/dir/product/needles';
my $expected = $clone_job . '1234 _GROUP=0 TEST=my_test@user/repo#my/branch BUILD=user/repo#9128 ' . $dirs;
my $expected_re = qr/${expected}/;
test_once $args, $expected_re, 'clone-job command line is correct';
test_once "-v $args", qr/\+ local dry_run/, 'clone-job with -v prints commands';
test_once "-n -v $args", qr/\+ local dry_run/, 'clone-job with -n -v prints commands';
my $args_branch = 'https://github.com/user/repo/tree/my/branch https://openqa.opensuse.org/tests/1234 FOO=bar';
my $expected_branch_re
  = qr{${clone_job}1234 _GROUP=0 TEST=my_test\@user/repo#my/branch BUILD=user/repo#my/branch ${dirs} FOO=bar};
test_once $args_branch, $expected_branch_re, 'alternative mode with branch reference also yields right variables';
my $prefix = 'env repo_name=user/repo pr=9128 host=https://openqa.opensuse.org job=1234';
combined_like { $ret = run_once('', $prefix) } $expected_re, 'environment variables can be used instead';
is $ret, 0, 'exits successfully';
$prefix .= ' testsuite=new_test needles_dir=/my/needles productdir=my/product';
$dirs = 'PRODUCTDIR=my/product NEEDLES_DIR=/my/needles';
my $expected_custom_re = qr{https://openqa.opensuse.org 1234 _GROUP=0 TEST=new_test\@user/repo#my/branch.*${dirs}};
combined_like { $ret = run_once('', $prefix) } $expected_custom_re, 'testsuite and dirs can be overridden';
is $ret, 0, 'exits successfully';
my $args_trailing = 'https://github.com/me/repo/pull/1/ https://openqa.opensuse.org/tests/1';
test_once $args_trailing, qr{TEST=my_test\@user/repo#my/branch.*}, 'trailing slash ignored';
my $args_list = $args . ',https://openqa.opensuse.org/tests/1234';
$expected_re = qr/${expected}.*opensuse.org 1234/s;
test_once $args_list, $expected_re, 'accepts comma-separated list of jobs';
$args_list .= ' FOO=bar';
$expected_re = qr/${expected} FOO=bar.*opensuse.org 1234.*FOO=bar/s;
test_once $args_list, $expected_re, 'additional arguments are passed as test parameters for each job';
my $args_clone = '--clone-job-args="--show-progress" ' . $args;
$expected_re = qr/openqa-clone-job --show-progress --skip-chained-deps --within-instance https/;
test_once $args_clone, $expected_re, 'additional parameters can be passed to clone-job';

my $args_escape
  = q(https://github.com/me/repo/pull/1/ https://openqa.opensuse.org/tests/1 TEST1=$FOO_BAR 'TEST2=$VAR' TEST3=space\\ space 'TEST4=(!?bla)');
$ENV{FOO_BAR} = 'BLUB';
$expected_re = qr/TEST1=BLUB\r?\nTEST2=\$VAR\r?\nTEST3=space space\r?\nTEST4=\(!\?bla\)$/m;
combined_like { run_once($args_escape, q(dry_run='printf "%s\n"')) } $expected_re,
  'Custom variables has proper bash escaping';

TODO: {
    local $TODO = 'not implemented';
    $args = 'https://github.com/user/repo/pull/9128 https://openqa.opensuse.org/t1234';
    test_once $args, qr/${expected}/, 'short test URLs are supported the same';
    $args .= ',https://openqa.suse.de/t1234';
    test_once $args, qr/${expected}.* 1234/s, 'multiple short URLs from different hosts point to individual hosts';
}

my $test_url = 'https://openqa.opensuse.org/tests/1107158';
$ENV{curl_github} = qq{echo -e '{"head": {"label": "user:my_branch"}, "body": "\@openqa: Clone ${test_url}"}'; true};
$args = 'https://github.com/user/repo/pull/9128';
$expected = $clone_job . '1107158 _GROUP=0 TEST=my_test@user/repo#my_branch BUILD=user/repo#9128 ';
$expected_re = qr/${expected}/s;
test_once $args, $expected_re, 'clone-job command with test from PR description';

$ENV{curl_github} = qq{echo -e '{"head": {"label": "user:my_branch"}, "body": "- \@openqa: Clone ${test_url}"}'; true};
test_once $args, $expected_re, 'clone-job command with test from PR description in list form';

$test_url = 'https://openqa.opensuse.org/tests/1169326';
$ENV{curl_github}
  = qq{echo -e '{"head": {"label": "user:my_branch"}, "body": "https://progress.opensuse.org/issues/8888 (https://openqa.opensuse.org/tests/9999)"}'; true};
$args = 'https://github.com/user/repo/pull/9539 https://openqa.opensuse.org/tests/1169326';
$expected = $clone_job . '1169326 _GROUP=0 TEST=my_test@user/repo#my_branch BUILD=user/repo#9539 ';
$expected_re = qr/${expected}/s;
test_once $args, $expected_re, 'clone-job command with multiple URLs in PR and job URL';

$ENV{curl_github} = qq{echo -e '{"head": {"label": "user:my/branch"}, "body": "Lorem ipsum"}'; true};
$ENV{curl_openqa}
  = qq{echo -e '{"TEST": "my_test", "CASEDIR": "/var/lib/openqa/pool/25/os-autoinst-distri-opensuse", "PRODUCTDIR": "os-autoinst-distri-opensuse/products/sle", "NEEDLES_DIR": "/var/lib/openqa/pool/25/os-autoinst-distri-opensuse/products/sle/needles"}'; true};
$dirs
  = 'CASEDIR=https://github.com/user/repo.git#my/branch PRODUCTDIR=repo/products/sle NEEDLES_DIR=/var/lib/openqa/pool/25/os-autoinst-distri-opensuse/products/sle/needles';
$expected = $clone_job . '1169326 _GROUP=0 TEST=my_test@user/repo#my/branch BUILD=user/repo#9539 ' . $dirs;
$expected_re = qr/${expected}/;
test_once $args, $expected_re, "PRODUCTDIR is correct when the source job's PRODUCTDIR is a relative directory";

$ENV{curl_openqa}
  = qq{echo -e '{"TEST": "my_test", "CASEDIR": "/var/lib/openqa/cache/openqa1-opensuse/tests/opensuse", "PRODUCTDIR": "/var/lib/openqa/cache/openqa1-opensuse/tests/opensuse/products/opensuse"}'; true};
$dirs
  = 'CASEDIR=https://github.com/user/repo.git#my/branch PRODUCTDIR=repo/products/opensuse NEEDLES_DIR=/var/lib/openqa/cache/openqa1-opensuse/tests/opensuse/products/opensuse/needles';
$expected = $clone_job . '1169326 _GROUP=0 TEST=my_test@user/repo#my/branch BUILD=user/repo#9539 ' . $dirs;
$expected_re = qr/${expected}/;
test_once $args, $expected_re, "PRODUCTDIR is correct when the source job's PRODUCTDIR includes specific word";

done_testing;
