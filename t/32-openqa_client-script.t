#!/usr/bin/env perl
# Copyright 2019-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use strict;
use warnings;
use Test::Exception;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '10';
use OpenQA::Test::Utils qw(run_cmd test_cmd);


sub test_once {
    # Report failure at the callsite instead of the test function
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    # prevent all network access to stay local
    test_cmd('unshare -r -n script/client', @_);
}

test_once '', qr/Usage:/, 'hint shown for mandatory parameter missing', 1, 'needs parameters';
test_once '--help', qr/Usage:/, 'help text shown', 0, 'help screen is success';
test_once '--invalid-arg', qr/Usage:/, 'invalid args also yield help', 1, 'help screen on invalid not success';
my $args = 'jobs 1';
test_once $args, qr/ERROR.*not connected/, 'fails without network', 1, 'fail';

done_testing();
