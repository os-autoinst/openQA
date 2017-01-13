# Copyright (C) 2016 SUSE LLC
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

use strict;
use warnings;
use OpenQA::Utils;
use OpenQA::Test::Case;
use OpenQA::Client;
use Test::More;
use Test::Mojo;
use Test::Warnings;
use Test::Output qw(stdout_like stderr_like);
use Test::Fatal;

use OpenQA::Worker::Common;
use OpenQA::Worker::Jobs;

# api_init (must be called before making other calls anyways)
like(
    exception {
        OpenQA::Worker::Common::api_init(
            {HOSTS => ['http://any_host']},
            {
                host => 'http://any_host',
            })
    },
    qr/API key.*needed/,
    'auth required'
);


OpenQA::Worker::Common::api_init(
    {HOSTS => ['this_host_should_not_exist']},
    {
        host      => 'this_host_should_not_exist',
        apikey    => '1234',
        apisecret => '4321',
    });
ok($hosts->{this_host_should_not_exist},      'entry for host created');
ok($hosts->{this_host_should_not_exist}{ua},  'user agent created');
ok($hosts->{this_host_should_not_exist}{url}, 'url object created');
is($hosts->{this_host_should_not_exist}{workerid}, undef, 'worker not registered yet');

# api_call
eval { api_call() };
ok($@, 'no action or no worker id set');

$hosts->{this_host_should_not_exist}{workerid} = 1;
$current_host = 'this_host_should_not_exist';

sub test_via_io_loop {
    my ($test_function) = @_;
    add_timer('api_call', 0, $test_function, 1);
    Mojo::IOLoop->start;
}

test_via_io_loop sub {
    api_call(
        'post', 'jobs/500/status',
        json          => {status => 'RUNNING'},
        ignore_errors => 1,
        tries         => 1,
        callback => sub { my $res = shift; is($res, undef, 'error ignored') });

    stderr_like(
        sub {
            api_call(
                'post', 'jobs/500/status',
                json  => {status => 'RUNNING'},
                tries => 1,
                callback => sub { my $res = shift; is($res, undef, 'error handled'); Mojo::IOLoop->stop() });
            while (Mojo::IOLoop->is_running) { Mojo::IOLoop->singleton->reactor->one_tick }
        },
        qr/.*\[ERROR\] Connection error:.*(remaining tries: 0).*/i,
        'warning about 503 error'
    );
};

done_testing();
