#! /usr/bin/perl

# Copyright (C) 2014-2017 SUSE Linux Products GmbH
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

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use Test::Warnings ':all';
use Test::Output 'stderr_like';
use OpenQA::Test::Case;
use OpenQA::WebSockets::Client;
use Test::MockModule;

OpenQA::Test::Case->new->init_data;

my $mock_client = Test::MockModule->new('OpenQA::WebSockets::Client');
my ($client_called, $last_command);
$mock_client->mock(
    send_msg => sub {
        my ($self, $workerid, $command, $jobid) = @_;
        $client_called++;
        $last_command = $command;
    });

my $schema = OpenQA::Schema::connect_db(mode => 'test', check => 0);
#issue valid commands for worker 1
my @valid_commands = qw(quit abort cancel obsolete livelog_stop livelog_start developer_session_start);

my $worker = $schema->resultset('Workers')->find(1);

for my $cmd (@valid_commands) {
    $worker->send_command(command => $cmd, job_id => 0);
    is($last_command, $cmd, "command $cmd received at WS server");
}

#issue invalid commands
stderr_like { $worker->send_command(command => 'foo', job_id => 0); }
qr/\[ERROR\] Trying to issue unknown command "foo" for worker "localhost:"/;
isnt($last_command, 'foo', 'refuse invalid commands');
ok $client_called, 'mocked send_msg method has been called';

done_testing();
