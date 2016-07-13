BEGIN { unshift @INC, 'lib'; }

# Copyright (C) 2016 Red Hat
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
use Test::MockModule;
use Test::More;
use Test::Mojo;
use Test::Warnings;

my $args;

# this is a mock IPC::Run which just stores the args it's called with
# so we can check the plugin did the right thing
sub mock_ipc_run {
    my ($cmd, $stdin, $stdout, $stderr) = @_;
    $args = join(" ", @$cmd);
}

my $module = new Test::MockModule('IPC::Run');
$module->mock('run', \&mock_ipc_run);

my $schema = OpenQA::Test::Database->new->create();

# this test also serves to test plugin loading via config file
$ENV{OPENQA_CONFIG} = 't';
open(my $fd, '>', $ENV{OPENQA_CONFIG} . '/openqa.ini');
print $fd "[global]\n";
print $fd "plugins=Fedmsg\n";
close $fd;

my $t = Test::Mojo->new('OpenQA::WebAPI');

# XXX: Test::Mojo loses its app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')->ioloop(Mojo::IOLoop->singleton));
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
is($args, 'fedmsg-logger --cert-prefix=openqa --modname=openqa --topic=job.create --json-input --message={"ARCH":"x86_64","BUILD":"666","DESKTOP":"DESKTOP","DISTRI":"Unicorn","FLAVOR":"pink","ISO":"whatever.iso","ISO_MAXSIZE":"1","KVM":"KVM","MACHINE":"RainbowPC","TEST":"rainbow","VERSION":"42","id":' . $job . ',"remaining":1}', "job create triggers fedmsg");

# FIXME: restarting job via API emits an event in real use, but not if we do it here

# set the job as done via API
$post = $t->post_ok("/api/v1/jobs/" . $job . "/set_done")->status_is(200);
# check plugin called fedmsg-logger correctly
is($args, 'fedmsg-logger --cert-prefix=openqa --modname=openqa --topic=job.done --json-input --message={"ARCH":"x86_64","BUILD":"666","FLAVOR":"pink","ISO":"whatever.iso","MACHINE":"RainbowPC","TEST":"rainbow","id":' . $job . ',"newbuild":null,"remaining":0,"result":"failed"}', "job done triggers fedmsg");

# we don't test update_results as comment indicates it's obsolete

# duplicate the job via API
$post = $t->post_ok("/api/v1/jobs/" . $job . "/duplicate")->status_is(200);
my $newjob = $post->tx->res->json->{id};
# check plugin called fedmsg-logger correctly
is($args, 'fedmsg-logger --cert-prefix=openqa --modname=openqa --topic=job.duplicate --json-input --message={"ARCH":"x86_64","BUILD":"666","FLAVOR":"pink","ISO":"whatever.iso","MACHINE":"RainbowPC","TEST":"rainbow","auto":null,"id":' . $job . ',"remaining":1,"result":' . $newjob . '}', "job duplicate triggers fedmsg");

# cancel the new job via API
$post = $t->post_ok("/api/v1/jobs/" . $newjob . "/cancel")->status_is(200);
# check plugin called fedmsg-logger correctly
is($args, 'fedmsg-logger --cert-prefix=openqa --modname=openqa --topic=job.cancel --json-input --message={"ARCH":"x86_64","BUILD":"666","FLAVOR":"pink","ISO":"whatever.iso","MACHINE":"RainbowPC","TEST":"rainbow","id":' . $newjob . ',"remaining":0}', "job cancel triggers fedmsg");

# FIXME: deleting job via DELETE call to api/v1/jobs/$newjob fails with 500?

done_testing();
