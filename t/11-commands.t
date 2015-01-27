# Copyright (C) 2014 SUSE Linux Products GmbH
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
# with this program; if not, see <http://www.gnu.org/licenses/>.

BEGIN {
    unshift @INC, 'lib', 'lib/OpenQA';
}

use Mojo::Base -strict;
use Test::More tests => 27;
use Test::Mojo;
use Mojo::URL;
use OpenQA::Test::Case;
use OpenQA::Client;
use OpenQA::Scheduler;

OpenQA::Test::Case->new->init_data;

my $t = Test::Mojo->new('OpenQA');

# XXX: Test::Mojo loses it's app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(OpenQA::Client->new()->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

#get websocket connection
$t->ua->apikey('PERCIVALKEY02');
$t->ua->apisecret('PERCIVALSECRET02');
my $ws = $t->websocket_ok('/api/v1/workers/1/ws');

#issue valid commands for worker 1
my @valid_commands = qw/quit abort cancel obsolete
  stop_waitforneedle reload_needles_and_retry continue_waitforneedle
  enable_interactive_mode disable_interactive_mode job_available
  livelog_stop livelog_start/;

for my $cmd (@valid_commands) {
    OpenQA::Scheduler::command_enqueue(workerid => 1, command => $cmd);
    $ws->message_ok;
    $ws->message_is($cmd);
}

#issue invalid commands
eval {OpenQA::Scheduler::command_enqueue(workerid => 1, command => 'foo');};
ok($@, 'refuse invalid commands');

$ws->finish_ok;
done_testing();
