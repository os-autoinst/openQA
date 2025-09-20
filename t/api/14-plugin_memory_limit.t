# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojolicious;

use_ok('OpenQA::WebAPI::Plugin::MemoryLimit');

my $app = Mojolicious->new;
$app->config->{global}{max_rss_limit} = 42;
OpenQA::WebAPI::Plugin::MemoryLimit->register($app, undef);

done_testing;
