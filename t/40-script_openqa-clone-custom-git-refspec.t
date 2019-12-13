# Copyright (C) 2019 SUSE LLC
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
    my ($args) = @_;
    $args //= '';
    # prevent all network access to stay local
    my $cmd = "unshare -r -n script/openqa-clone-custom-git-refspec $args";
    note("Calling '$cmd'");
    system("$cmd") >> 8;
}

my $ret;
stderr_like(sub { $ret = run_once() }, qr/Need.*parameter/, 'help text shown');
is $ret, 1, 'openqa-clone-custom-git-refspec needs parameters';
my $args
  = 'https://github.com/os-autoinst/os-autoinst-distri-opensuse/pull/9128 https://openqa.opensuse.org/tests/1107158';
isnt run_once($args), 0, 'without network we fail (without error)';
# mock any external access with all arguments
$ENV{curl_github} = qq{echo -e '{"head": {"label": "user:my_branch"}}'; true};
$ENV{curl_openqa}
  = qq{echo -e '{"TEST": "my_test", "CASEDIR": "/my/case/dir", "PRODUCTDIR": "/my/case/dir/product", "NEEDLES_DIR": "/my/case/dir/product/needles"}'; true};
my $expected
  = qr{openqa-clone-job --skip-chained-deps --within-instance https://openqa.opensuse.org 1107158 _GROUP=0 TEST=my_test\@user/os-autoinst-distri-opensuse#my_branch BUILD=user/os-autoinst-distri-opensuse#9128 CASEDIR=https://github.com/user/os-autoinst-distri-opensuse.git#my_branch PRODUCTDIR=os-autoinst-distri-opensuse/product NEEDLES_DIR=/my/case/dir/product/needles};
stdout_like sub { $ret = run_once($args); }, $expected, 'clone-job command line is correct';
is $ret, 0, 'command exits successfully';

done_testing;
