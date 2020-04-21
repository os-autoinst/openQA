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
use Test::MockModule;
use Test::MockObject;
use Test::Output;
use OpenQA::WebAPI;
use OpenQA::Test::Case;

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

is OpenQA::Client::prepend_api_base('jobs'),      '/api/v1/jobs', 'API base prepended';
is OpenQA::Client::prepend_api_base('/my_route'), '/my_route',    'API base not prepended for absolute paths';
throws_ok sub { OpenQA::Client::run }, qr/Need \@args/, 'needs arguments parsed from command line';

my %options      = (verbose => 1);
my $client_mock  = Test::MockModule->new('OpenQA::UserAgent');
my $code         = 200;
my $headers_mock = Test::MockObject->new()->set_always(content_type => 'application/json');
my $code_mock    = Test::MockObject->new()->mock(code => sub { $code })->mock(headers => sub { $headers_mock })
  ->set_always(json => 'my_json')->set_always(body => 'body');
my $res = Test::MockObject->new()->mock(res => sub { $code_mock });
$client_mock->redefine(
    new => sub {
        Test::MockObject->new()->mock(get => sub { $res });
    });

is OpenQA::Client::run(\%options, qw(jobs)), 'my_json', 'returns job data';

done_testing();
