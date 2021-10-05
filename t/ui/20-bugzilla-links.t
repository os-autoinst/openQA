# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '8';
use OpenQA::Test::Case;

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl');

my $t = Test::Mojo->new('OpenQA::WebAPI');

#
# Very simple test to verify we end up on a useful page for old links
#
$t->get_ok('/tests/99938/modules/logpackages/steps/1')->status_is(302);
$t->header_like(Location => qr,(?:\Qhttp://localhost:\E\d+)?\Q/tests/99938#step/logpackages/1\E,);

done_testing();
