#! /usr/bin/perl

# Copyright (C) 2016-2017 SUSE LLC
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

BEGIN {
    unshift @INC, 'lib';
    $ENV{OPENQA_TEST_IPC} = 1;
}

use Mojo::Base;
use Mojo::IOLoop;

use FindBin;
use lib "$FindBin::Bin/lib";
use OpenQA::Client;
use OpenQA::Scheduler;
use OpenQA::WebSockets;
use OpenQA::Test::Database;
use Test::MockModule;
use Test::More;
use Test::Mojo;
use Test::Warnings;
use Mojo::File qw(tempdir path);
use JSON qw(decode_json);
use OpenQA::WebAPI::Plugin::AMQP;

my %published;

my $plugin_mock = Test::MockModule->new('OpenQA::WebAPI::Plugin::AMQP');
$plugin_mock->mock(
    publish_amqp => sub {
        my ($self, $topic, $data) = @_;
        $published{$topic} = $data;
    });

my $schema = OpenQA::Test::Database->new->create();

# this test also serves to test plugin loading via config file
my @conf = ("[global]\n", "plugins=AMQP\n");
my $tempdir = tempdir;
$ENV{OPENQA_CONFIG} = $tempdir;
path($ENV{OPENQA_CONFIG})->make_path->child("openqa.ini")->spurt(@conf);

my $t = Test::Mojo->new('OpenQA::WebAPI');

# XXX: Test::Mojo loses its app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(
    OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

# create a parent group
my $parent_groups = $app->schema->resultset('JobGroupParents');
$parent_groups->create(
    {
        id   => 2000,
        name => 'test',
    });

# create Test DBus bus and service for fake WebSockets
my $ws = OpenQA::WebSockets->new();
my $sh = OpenQA::Scheduler->new();

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
my $job;
subtest 'create job' => sub {
    my $post = $t->post_ok("/api/v1/jobs" => form => $settings)->status_is(200);
    ok($job = $post->tx->res->json->{id}, 'got ID of new job');
    is(
        $published{'suse.openqa.job.create'},
        '{"ARCH":"x86_64","BUILD":"666","DESKTOP":"DESKTOP","DISTRI":"Unicorn","FLAVOR":"pink","ISO":"whatever.iso",'
          . '"ISO_MAXSIZE":"1","KVM":"KVM","MACHINE":"RainbowPC","TEST":"rainbow","VERSION":"42","group_id":null,"id":'
          . $job
          . ',"remaining":1}',
        "job create triggers amqp"
    );
};

subtest 'mark job as done' => sub {
    my $post = $t->post_ok("/api/v1/jobs/$job/set_done")->status_is(200);
    is(
        $published{'suse.openqa.job.done'},
        '{"ARCH":"x86_64","BUILD":"666","FLAVOR":"pink","ISO":"whatever.iso","MACHINE":"RainbowPC",'
          . '"TEST":"rainbow","group_id":null,"id":'
          . $job
          . ',"newbuild":null,"remaining":0,"result":"failed"}',
        "job done triggers amqp"
    );
};

subtest 'duplicate and cancel job' => sub {
    my $post   = $t->post_ok("/api/v1/jobs/$job/duplicate")->status_is(200);
    my $newjob = $post->tx->res->json->{id};
    is(
        $published{'suse.openqa.job.duplicate'},
        '{"ARCH":"x86_64","BUILD":"666","FLAVOR":"pink","ISO":"whatever.iso","MACHINE":"RainbowPC",'
          . '"TEST":"rainbow","auto":0,"group_id":null,"id":'
          . $job
          . ',"remaining":1,"result":'
          . $newjob . '}',
        'job duplicate triggers amqp'
    );

    $post = $t->post_ok("/api/v1/jobs/$newjob/cancel")->status_is(200);
    is(
        $published{'suse.openqa.job.cancel'},
        '{"ARCH":"x86_64","BUILD":"666","FLAVOR":"pink","ISO":"whatever.iso","MACHINE":"RainbowPC",'
          . '"TEST":"rainbow","group_id":null,"id":'
          . $newjob
          . ',"remaining":0}',
        "job cancel triggers amqp"
    );
};

sub assert_common_comment_json {
    my ($json) = @_;
    ok($json->{id}, 'id');
    is($json->{job_id}, undef,   'job id');
    is($json->{text},   'test',  'text');
    is($json->{user},   'perci', 'user');
    ok($json->{created}, 't_created');
    ok($json->{updated}, 't_updated');
}

subtest 'create job group comment' => sub {
    my $post = $t->post_ok('/api/v1/groups/1001/comments' => form => {text => 'test'})->status_is(200);
    my $json = decode_json($published{'suse.openqa.comment.create'});
    assert_common_comment_json($json);
    is($json->{group_id},        1001,  'job group id');
    is($json->{parent_group_id}, undef, 'parent group id');
};

subtest 'create parent group comment' => sub {
    my $post = $t->post_ok('/api/v1/parent_groups/2000/comments' => form => {text => 'test'})->status_is(200);
    my $json = decode_json($published{'suse.openqa.comment.create'});
    assert_common_comment_json($json);
    is($json->{group_id},        undef, 'job group id');
    is($json->{parent_group_id}, 2000,  'parent group id');
};

done_testing();
