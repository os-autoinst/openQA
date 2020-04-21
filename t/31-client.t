# Copyright (C) 2018-2020 SUSE LLC
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
# You should have received a copy of the GNU General Public License

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "lib";

use Test::Exception;
use Test::More;
use Test::Mojo;
use OpenQA::WebAPI;

subtest 'client instantiation prevented from the daemons itself' => sub {
    OpenQA::WebSockets::Client::mark_current_process_as_websocket_server;
    throws_ok(
        sub {
            OpenQA::WebSockets::Client->singleton;
        },
        qr/is forbidden/,
        'can not create ws server client from ws server itself'
    );

    OpenQA::Scheduler::Client::mark_current_process_as_scheduler;
    throws_ok(
        sub {
            OpenQA::Scheduler::Client->singleton;
        },
        qr/is forbidden/,
        'can not create scheduler client from scheduler itself'
    );
};

done_testing();
