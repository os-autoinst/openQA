#!/usr/bin/env perl
# Copyright 2019-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '10';
use OpenQA::Test::Utils qw(run_cmd test_cmd);


sub test_once {
    # Report failure at the callsite instead of the test function
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    # prevent all network access to stay local
    test_cmd('OPENQA_CONFIG= unshare -r -n script/openqa-clone-job', @_);
}

test_once '', qr/missing.*help for usage/, 'hint shown for mandatory parameter missing', 255, 'needs parameters';
test_once '--help', qr/Usage:/, 'help text shown', 0, 'help screen is success';
test_once '--invalid-arg', qr/Usage:/, 'invalid args also yield help', 1, 'help screen on invalid not success';
my $args = 'http://openqa.opensuse.org/t1';
test_once $args, qr|API key/secret missing|, 'fails without API key/secret', 'non-zero', 'fail';
test_once "--apikey foo --apisecret bar $args", qr/failed to get job '1'/, 'fails without network', 'non-zero', 'fail';

done_testing();
