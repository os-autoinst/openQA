# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings ':report_warnings';
use Test::MockObject;
use Mojolicious;
use FindBin;

use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";

use OpenQA::Test::TimeLimit '5';

use_ok('OpenQA::WebAPI::Plugin::ObsRsync::Task');

my $job = Test::MockObject->new->mock('retries', sub { 42 })->set_true('retry')->set_true('finish');

OpenQA::WebAPI::Plugin::ObsRsync::Task::_retry_or_finish($job, undef, undef, 1, 1);

done_testing;
