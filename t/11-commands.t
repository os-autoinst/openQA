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
    unshift @INC, 'lib';
}

use Test::More;
use Test::Warnings ':all';
use Test::Output qw/stderr_like/;
use OpenQA::Test::Case;
use OpenQA::Client;
use OpenQA::Scheduler::Scheduler;
use OpenQA::WebSockets;

OpenQA::Test::Case->new->init_data;

# create Test DBus bus and service for fake WebSockets call
my $ipc = OpenQA::IPC->ipc('', 1);
my $ws = OpenQA::WebSockets->new;

# monkey patch ws_send of OpenQA::WebSockets::Server to store received command
package OpenQA::WebSockets::Server;
no warnings "redefine";
my $last_command = '';
sub ws_send {
    my ($workerid, $command, $jobid) = @_;
    $OpenQA::WebSockets::Server::last_command = $command;
}

package main;

my $schema = OpenQA::Schema::connect_db('test');
#issue valid commands for worker 1
my @valid_commands = qw/quit abort cancel obsolete
  stop_waitforneedle reload_needles_and_retry continue_waitforneedle
  enable_interactive_mode disable_interactive_mode job_available
  livelog_stop livelog_start/;

my $worker = $schema->resultset('Workers')->find(1);

for my $cmd (@valid_commands) {
    $worker->send_command(command => $cmd, job_id => 0);
    is($OpenQA::WebSockets::Server::last_command, $cmd, "command $cmd received at WS server");
}

#issue invalid commands
stderr_like { $worker->send_command(command => 'foo', job_id => 0); }
qr/\[ERROR\] Trying to issue unknown command "foo" for worker "localhost:"/;
isnt($OpenQA::WebSockets::Server::last_command, 'foo', 'refuse invalid commands');

done_testing();
