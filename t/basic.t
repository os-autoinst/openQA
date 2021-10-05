# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Mojo;
use Test::Warnings ':report_warnings';

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::Database;
use OpenQA::Test::TimeLimit '8';

OpenQA::Test::Database->new->create;
Test::Mojo->new('OpenQA::WebAPI')->get_ok('/')->status_is(200)->content_like(qr/Welcome to openQA/i);

done_testing;
