# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Capture::Tiny qw(capture);
use Mojolicious;
use Mojo::IOLoop;

use_ok 'OpenQA::WebAPI::Plugin::MemoryLimit';

my $app = Mojolicious->new;
$app->config->{global}{max_rss_limit} = 42;
local $ENV{OPENQA_RSS_CHECK_INTERVAL} = 0;

OpenQA::WebAPI::Plugin::MemoryLimit->register($app, undef);

# change the pid of the test
local $$ = $$ + 1;

# capture the loop
my ($out, $err) = capture { Mojo::IOLoop->start };

like $err, qr/Worker exceeded RSS limit "\d+ > 42", restarting/,
  'Debug error should be captured when value of worker rss is more than max';

done_testing;
