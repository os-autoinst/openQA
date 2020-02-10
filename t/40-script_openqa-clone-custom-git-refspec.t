# Copyright (C) 2019-2020 SUSE LLC
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

use strict;
use warnings;

use Test::More;
use Test::Warnings;
use Test::Output;

# instruct openqa-clone-custom-git-refspec to use dry-run modes for all calls
$ENV{dry_run} = 'echo';

sub run_once {
    my ($args, $prefix) = @_;
    $args //= '';
    $prefix = $prefix ? $prefix . ' ' : '';
    # prevent all network access to stay local
    my $cmd = "$prefix unshare -r -n script/openqa-clone-custom-git-refspec $args";
    note("Calling '$cmd'");
    system("$cmd") >> 8;
}

sub test_once {
    # Report failure at the callsite instead of the test function
    local $Test::Builder::Level = $Test::Builder::Level + 1;

    my ($args, $expected, $test_msg, $exit_code, $exit_code_msg) = @_;
    $expected      //= qr//;
    $test_msg      //= 'command line is correct';
    $exit_code     //= 0;
    $exit_code_msg //= 'command exits successfully';
    my $ret;
    combined_like sub { $ret = run_once($args); }, $expected, $test_msg;
    is $ret, $exit_code, $exit_code_msg;
    return $ret;
}

my $ret;
test_once '', qr/Need.*parameter/, 'hint shown for mandatory parameter missing', 1,
  'openqa-clone-custom-git-refspec needs parameters';
test_once '--help',        qr/Usage:/, 'help text shown',              0, 'help screen is regarded as success';
test_once '--invalid-arg', qr/Usage:/, 'invalid args also yield help', 0, 'help screen still success';
my $args = 'https://github.com/user/repo/pull/9128 https://openqa.opensuse.org/tests/1234';
isnt run_once($args), 0, 'without network we fail (without error)';
# mock any external access with all arguments
$ENV{curl_github} = qq{echo -e '{"head": {"label": "user:my_branch"}}'; true};
$ENV{curl_openqa}
  = qq{echo -e '{"TEST": "my_test", "CASEDIR": "/my/case/dir", "PRODUCTDIR": "/my/case/dir/product", "NEEDLES_DIR": "/my/case/dir/product/needles"}'; true};
my $clone_job = 'openqa-clone-job --skip-chained-deps --within-instance https://openqa.opensuse.org ';
my $dirs
  = 'CASEDIR=https://github.com/user/repo.git#my_branch PRODUCTDIR=repo/product NEEDLES_DIR=/my/case/dir/product/needles';
my $expected    = $clone_job . '1234 _GROUP=0 TEST=my_test@user/repo#my_branch BUILD=user/repo#9128 ' . $dirs;
my $expected_re = qr/${expected}/;
test_once $args, $expected_re, 'clone-job command line is correct';
my $args_branch = 'https://github.com/user/repo/tree/my_branch https://openqa.opensuse.org/tests/1234 FOO=bar';
my $expected_branch_re
  = qr{${clone_job}1234 _GROUP=0 TEST=my_test\@user/repo#my_branch BUILD=user/repo#my_branch ${dirs} FOO=bar};
test_once $args_branch, $expected_branch_re, 'alternative mode with branch reference also yields right variables';
my $prefix = 'env repo_name=user/repo pr=9128 host=https://openqa.opensuse.org job=1234';
combined_like sub { $ret = run_once('', $prefix) }, $expected_re, 'environment variables can be used instead';
is $ret, 0, 'exits successfully';
$prefix .= ' testsuite=new_test needles_dir=/my/needles productdir=my/product';
$dirs = 'PRODUCTDIR=my/product NEEDLES_DIR=/my/needles';
my $expected_custom_re = qr{https://openqa.opensuse.org 1234 _GROUP=0 TEST=new_test\@user/repo#my_branch.*${dirs}};
combined_like sub { $ret = run_once('', $prefix) }, $expected_custom_re, 'testsuite and dirs can be overridden';
is $ret, 0, 'exits successfully';
my $args_trailing = 'https://github.com/me/repo/pull/1/ https://openqa.opensuse.org/tests/1';
test_once $args_trailing, qr{TEST=my_test\@user/repo#my_branch.*}, 'trailing slash ignored';
$args .= ',https://openqa.opensuse.org/tests/1234';
$expected_re = qr/${expected}.*opensuse.org 1234/s;
test_once $args, $expected_re, 'accepts comma-separated list of jobs';
$args .= ' FOO=bar';
$expected_re = qr/${expected} FOO=bar.*opensuse.org 1234.*FOO=bar/s;
test_once $args, $expected_re, 'additional arguments are passed as test parameters for each job';

TODO: {
    local $TODO = 'not implemented';
    $args = 'https://github.com/user/repo/pull/9128 https://openqa.opensuse.org/t1234';
    test_once $args, qr/${expected}/, 'short test URLs are supported the same';
    $args .= ',https://openqa.suse.de/t1234';
    test_once $args, qr/${expected}.* 1234/s, 'multiple short URLs from different hosts point to individual hosts';
}

done_testing;
