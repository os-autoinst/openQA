BEGIN { unshift @INC, 'lib'; }

# Copyright (C) 2016 SUSE Linux LLC
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use Mojo::Base;
use Mojo::IOLoop;

use OpenQA::Client;
use OpenQA::IPC;
use OpenQA::Scheduler;
use OpenQA::WebSockets;
use OpenQA::Test::Database;
use Net::DBus;
use Net::DBus::Test::MockObject;
use Test::MockObject;
use Test::More;
use Test::Mojo;
use Test::Warnings;

my %client_context;

my $client_mock = Test::MockObject->new();
$client_mock->fake_module(
    'Mojo::RabbitMQ::Client',
    new => sub {
        my $self = shift;
        my %args = @_;
        $client_context{url} = $args{url};

        return $self;
    },
    catch => sub { },
    on    => sub {
        my $self  = shift;
        my $event = shift;
        my $sub   = shift;
        $client_context{on}{$event} = $sub;
    },
    connect => sub {
        my $self = shift;
        $client_context{on}{open}($self);
    },
    open_channel => sub {
        my $self    = shift;
        my $channel = shift;
        $channel->connect();
    });

my %channel_context;
my $channel_mock = Test::MockObject->new();
$channel_mock->fake_module(
    'Mojo::RabbitMQ::Client::Channel',
    new => sub {
        my $self = shift;
        $channel_context{is_open} = 0;
        return $self;
    },
    catch => sub { },
    on    => sub {
        my $self  = shift;
        my $event = shift;
        my $sub   = shift;
        $channel_context{on}{$event} = $sub;
    },
    connect => sub {
        my $self = shift;
        $channel_context{on}{open}($self);
    },
    declare_exchange => sub {
        my $self = shift;
        my %args = @_;
        is($args{exchange}, 'pubsub', 'declare the right exchange');
        is($args{type},     'topic',  'declare the right exchange type');
        $channel_context{is_open}   = 1;
        $channel_context{delivered} = 0;
        return $self;
    },
    publish => sub {
        my $self = shift;
        my %args = @_;
        ok($channel_context{delivered}, 'previous command was delivered');
        $channel_context{delivered} = 0;
        $channel_context{last}{$args{routing_key}} = $args{body};
        return $self;
    },
    deliver => sub {
        my $self = shift;
        $channel_context{delivered} = 1;
    },
    is_open => sub {
        my $self = shift;
        return $channel_context{is_open};
    });

my $schema = OpenQA::Test::Database->new->create();

# this test also serves to test plugin loading via config file
$ENV{OPENQA_CONFIG} = 't';
open(my $fd, '>', $ENV{OPENQA_CONFIG} . '/openqa.ini');
print $fd "[global]\n";
print $fd "plugins=AMQP\n";
close $fd;

my $t = Test::Mojo->new('OpenQA::WebAPI');

# XXX: Test::Mojo loses its app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(
    OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

# create Test DBus bus and service for fake WebSockets
my $ipc = OpenQA::IPC->ipc('', 1);
my $ws  = OpenQA::WebSockets->new();
my $sh  = OpenQA::Scheduler->new();

my $settings = {
    DISTRI      => 'Unicorn',
    FLAVOR      => 'pink',
    VERSION     => '42',
    BUILD       => '666',
    TEST        => 'rainbow',
    ISO         => 'whatever.iso',
    DESKTOP     => 'DESKTOP',
    KVM         => 'KVM',
    ISO_MAXSIZE => 1,
    MACHINE     => "RainbowPC",
    ARCH        => 'x86_64'
};

# create a job via API
my $post = $t->post_ok("/api/v1/jobs" => form => $settings)->status_is(200);
my $job = $post->tx->res->json->{id};
is(
    $channel_context{last}{'suse.openqa.job.create'},
    '{"ARCH":"x86_64","BUILD":"666","DESKTOP":"DESKTOP","DISTRI":"Unicorn","FLAVOR":"pink","ISO":"whatever.iso",'
      . '"ISO_MAXSIZE":"1","KVM":"KVM","MACHINE":"RainbowPC","TEST":"rainbow","VERSION":"42","group_id":null,"id":'
      . $job
      . ',"remaining":1}',
    "job create triggers amqp"
);

# set the job as done via API
$post = $t->post_ok("/api/v1/jobs/" . $job . "/set_done")->status_is(200);
is(
    $channel_context{last}{'suse.openqa.job.done'},
    '{"ARCH":"x86_64","BUILD":"666","FLAVOR":"pink","ISO":"whatever.iso","MACHINE":"RainbowPC",'
      . '"TEST":"rainbow","group_id":null,"id":'
      . $job
      . ',"newbuild":null,"remaining":0,"result":"failed"}',
    "job done triggers amqp"
);

# duplicate the job via API
$post = $t->post_ok("/api/v1/jobs/" . $job . "/duplicate")->status_is(200);
my $newjob = $post->tx->res->json->{id};
is(
    $channel_context{last}{'suse.openqa.job.duplicate'},
    '{"ARCH":"x86_64","BUILD":"666","FLAVOR":"pink","ISO":"whatever.iso","MACHINE":"RainbowPC",'
      . '"TEST":"rainbow","auto":0,"group_id":null,"id":'
      . $job
      . ',"remaining":1,"result":'
      . $newjob . '}',
    "job duplicate triggers amqp"
);

# cancel the new job via API
$post = $t->post_ok("/api/v1/jobs/" . $newjob . "/cancel")->status_is(200);
is(
    $channel_context{last}{'suse.openqa.job.cancel'},
    '{"ARCH":"x86_64","BUILD":"666","FLAVOR":"pink","ISO":"whatever.iso","MACHINE":"RainbowPC",'
      . '"TEST":"rainbow","group_id":null,"id":'
      . $newjob
      . ',"remaining":0}',
    "job cancel triggers amqp"
);

done_testing();
