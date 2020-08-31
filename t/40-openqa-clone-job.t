#!/usr/bin/env perl
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

use Test::Most;
use FindBin;
use lib "$FindBin::Bin/lib";
use OpenQA::Test::Utils qw(run_cmd test_cmd);


sub test_once {
    # Report failure at the callsite instead of the test function
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    # prevent all network access to stay local
    test_cmd('unshare -r -n script/openqa-clone-job', @_);
}

test_once '', qr/missing.*help for usage/, 'hint shown for mandatory parameter missing', 255, 'needs parameters';
test_once '--help',        qr/Usage:/,     'help text shown',              0, 'help screen is success';
test_once '--invalid-arg', qr/Usage:/,     'invalid args also yield help', 1, 'help screen on invalid not success';
my $args = 'http://openqa.opensuse.org/t1';
test_once $args, qr/failed to get job '1'/, 'fails without network', 22, 'fail';

done_testing();
