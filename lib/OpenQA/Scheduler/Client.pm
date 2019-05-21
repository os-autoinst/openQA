# Copyright (C) 2014-2019 SUSE LLC
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

package OpenQA::Scheduler::Client;
use Mojo::Base -base;

use OpenQA::IPC;

sub wakeup {
    my $ipc = OpenQA::IPC->ipc;

    my $con = $ipc->{bus}->get_connection;

    # ugly work around for Net::DBus::Test not being able to handle us using low level API
    return if ref($con) eq 'Net::DBus::Test::MockConnection';

    my $msg = $con->make_method_call_message(
        "org.opensuse.openqa.Scheduler",
        "/Scheduler", "org.opensuse.openqa.Scheduler",
        "wakeup_scheduler"
    );
    # do not wait for a reply - avoid deadlocks. this way we can even call it
    # from within the scheduler without having to worry about reentering
    $con->send($msg);
}

sub singleton { state $client ||= __PACKAGE__->new }

1;
