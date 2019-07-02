#! /usr/bin/perl

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

use strict;
use warnings;

BEGIN {
    unshift @INC, 'lib';
}

use Mojo::IOLoop;

use FindBin;
use lib "$FindBin::Bin/lib";
use OpenQA::Client;
use OpenQA::Test::Database;
use Test::MockModule;
use Test::More;
use Test::Mojo;
use Test::Warnings;
use Mojo::File qw(tempdir path);

my @args;

# this is a mock IPC::Run which just stores the args it's called with
# so we can check the plugin did the right thing
sub mock_ipc_run {
    my ($cmd, $stdin, $stdout, $stderr) = @_;
    push @args, join(" ", @$cmd);
}

my $module = Test::MockModule->new('IPC::Run');
$module->mock('run', \&mock_ipc_run);

my $schema = OpenQA::Test::Database->new->create();

# this test also serves to test plugin loading via config file
my @conf    = ("[global]\n", "plugins=Fedmsg\n", "base_url=https://openqa.stg.fedoraproject.org\n");
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

my $settings = {
    DISTRI      => 'Unicorn',
    FLAVOR      => 'pink',
    VERSION     => '42',
    BUILD       => 'Fedora-Rawhide-20180129.n.0',
    TEST        => 'rainbow',
    ISO         => 'whatever.iso',
    DESKTOP     => 'DESKTOP',
    KVM         => 'KVM',
    ISO_MAXSIZE => 1,
    MACHINE     => "RainbowPC",
    ARCH        => 'x86_64'
};

my $commonexpr = '/usr/sbin/daemonize /usr/bin/fedmsg-logger-3 --cert-prefix=openqa --modname=openqa';
my $commonci   = '/usr/sbin/daemonize /usr/bin/fedmsg-logger-3 --cert-prefix=ci --modname=ci';
# create a job via API
$t->post_ok("/api/v1/jobs" => form => $settings)->status_is(200);
my $job = $t->tx->res->json->{id};
is(
    $args[0],
    $commonexpr
      . ' --topic=job.create --json-input --message='
      . '{"ARCH":"x86_64","BUILD":"Fedora-Rawhide-20180129.n.0","DESKTOP":"DESKTOP","DISTRI":"Unicorn","FLAVOR":"pink","ISO":"whatever.iso",'
      . '"ISO_MAXSIZE":"1","KVM":"KVM","MACHINE":"RainbowPC","TEST":"rainbow","VERSION":"42","id":'
      . $job
      . ',"remaining":1}',
    "job create triggers fedmsg"
);
is(
    $args[1],
    $commonci
      . ' --topic=productmd-compose.test.queued --json-input --message='
      . '{"body":{"artifact":{"id":"Fedora-Rawhide-20180129.n.0","iso":"whatever.iso","issuer":"releng","type":"productmd-compose"},"category":"validation",'
      . '"ci":{"email":"qa-devel@lists.fedoraproject.org","irc":"#fedora-qa","name":"Fedora openQA","team":"Fedora QA",'
      . '"url":"https://openqa.stg.fedoraproject.org"},"lifetime":240,"run":{"id":'
      . $job . ','
      . '"log":"https://openqa.stg.fedoraproject.org/tests/'
      . $job
      . '/file/autoinst-log.txt",'
      . '"url":"https://openqa.stg.fedoraproject.org/tests/'
      . $job . '"},'
      . '"type":"rainbow RainbowPC pink x86_64"},'
      . '"headers":{"id":"Fedora-Rawhide-20180129.n.0","type":"productmd-compose"}}',
    "job create triggers standardized fedmsg"
);
# reset $args
@args = ();

# FIXME: restarting job via API emits an event in real use, but not if we do it here

# set the job as done (implicit failed, it seems) via API
$t->post_ok("/api/v1/jobs/" . $job . "/set_done")->status_is(200);
# check plugin called fedmsg-logger-3 correctly
is(
    $args[0],
    $commonexpr
      . ' --topic=job.done --json-input --message='
      . '{"ARCH":"x86_64","BUILD":"Fedora-Rawhide-20180129.n.0","FLAVOR":"pink","ISO":"whatever.iso","MACHINE":"RainbowPC",'
      . '"TEST":"rainbow","id":'
      . $job
      . ',"newbuild":null,"remaining":0,"result":"failed"}',
    "job done triggers fedmsg"
);
is(
    $args[1],
    $commonci
      . ' --topic=productmd-compose.test.complete --json-input --message='
      . '{"body":{"artifact":{"id":"Fedora-Rawhide-20180129.n.0","iso":"whatever.iso","issuer":"releng","type":"productmd-compose"},"category":"validation",'
      . '"ci":{"email":"qa-devel@lists.fedoraproject.org","irc":"#fedora-qa","name":"Fedora openQA","team":"Fedora QA",'
      . '"url":"https://openqa.stg.fedoraproject.org"},"run":{"id":'
      . $job . ','
      . '"log":"https://openqa.stg.fedoraproject.org/tests/'
      . $job
      . '/file/autoinst-log.txt",'
      . '"url":"https://openqa.stg.fedoraproject.org/tests/'
      . $job . '"},'
      . '"status":"failed","type":"rainbow RainbowPC pink x86_64"},'
      . '"headers":{"id":"Fedora-Rawhide-20180129.n.0","type":"productmd-compose"}}',
    "job done triggers standardized fedmsg"
);
# reset $args
@args = ();

# we don't test update_results as comment indicates it's obsolete

# duplicate the job via API
$t->post_ok("/api/v1/jobs/" . $job . "/duplicate")->status_is(200);
my $newjob = $t->tx->res->json->{id};
# check plugin called fedmsg-logger-3 correctly
is(
    $args[0],
    $commonexpr
      . ' --topic=job.duplicate --json-input --message='
      . '{"ARCH":"x86_64","BUILD":"Fedora-Rawhide-20180129.n.0","FLAVOR":"pink","ISO":"whatever.iso","MACHINE":"RainbowPC",'
      . '"TEST":"rainbow","auto":0,"id":'
      . $job
      . ',"remaining":1,"result":'
      . $newjob . '}',
    "job duplicate triggers fedmsg"
);
is(
    $args[1],
    $commonci
      . ' --topic=productmd-compose.test.queued --json-input --message='
      . '{"body":{"artifact":{"id":"Fedora-Rawhide-20180129.n.0","iso":"whatever.iso","issuer":"releng","type":"productmd-compose"},"category":"validation",'
      . '"ci":{"email":"qa-devel@lists.fedoraproject.org","irc":"#fedora-qa","name":"Fedora openQA","team":"Fedora QA",'
      . '"url":"https://openqa.stg.fedoraproject.org"},"lifetime":240,"run":{"clone_of":'
      . $job
      . ',"id":'
      . $newjob . ','
      . '"log":"https://openqa.stg.fedoraproject.org/tests/'
      . $newjob
      . '/file/autoinst-log.txt",'
      . '"url":"https://openqa.stg.fedoraproject.org/tests/'
      . $newjob . '"},'
      . '"type":"rainbow RainbowPC pink x86_64"},'
      . '"headers":{"id":"Fedora-Rawhide-20180129.n.0","type":"productmd-compose"}}',
    "job duplicate triggers standardized fedmsg"
);
# reset $args
@args = ();

# cancel the new job via API
$t->post_ok("/api/v1/jobs/" . $newjob . "/cancel")->status_is(200);
# check plugin called fedmsg-logger-3 correctly
is(
    $args[0],
    $commonexpr
      . ' --topic=job.cancel --json-input --message='
      . '{"ARCH":"x86_64","BUILD":"Fedora-Rawhide-20180129.n.0","FLAVOR":"pink","ISO":"whatever.iso","MACHINE":"RainbowPC",'
      . '"TEST":"rainbow","id":'
      . $newjob
      . ',"remaining":0}',
    "job cancel triggers fedmsg"
);
is(
    $args[1],
    $commonci
      . ' --topic=productmd-compose.test.error --json-input --message='
      . '{"body":{"artifact":{"id":"Fedora-Rawhide-20180129.n.0","iso":"whatever.iso","issuer":"releng","type":"productmd-compose"},"category":"validation",'
      . '"ci":{"email":"qa-devel@lists.fedoraproject.org","irc":"#fedora-qa","name":"Fedora openQA","team":"Fedora QA",'
      . '"url":"https://openqa.stg.fedoraproject.org"},"reason":"user_cancelled","run":{"id":'
      . $newjob . ','
      . '"log":"https://openqa.stg.fedoraproject.org/tests/'
      . $newjob
      . '/file/autoinst-log.txt",'
      . '"url":"https://openqa.stg.fedoraproject.org/tests/'
      . $newjob . '"},'
      . '"type":"rainbow RainbowPC pink x86_64"},'
      . '"headers":{"id":"Fedora-Rawhide-20180129.n.0","type":"productmd-compose"}}',
    "job cancel triggers standardized fedmsg"
);

# duplicate the job once more via API (so we can test 'passed')
$t->post_ok("/api/v1/jobs/" . $newjob . "/duplicate")->status_is(200);
my $newerjob = $t->tx->res->json->{id};

# reset $args
@args = ();

# set the job as done (explicit passed) via API
$t->post_ok("/api/v1/jobs/" . $newerjob . "/set_done?result=passed")->status_is(200);
# check plugin called fedmsg-logger-3 correctly
is(
    $args[0],
    $commonexpr
      . ' --topic=job.done --json-input --message='
      . '{"ARCH":"x86_64","BUILD":"Fedora-Rawhide-20180129.n.0","FLAVOR":"pink","ISO":"whatever.iso","MACHINE":"RainbowPC",'
      . '"TEST":"rainbow","id":'
      . $newerjob
      . ',"newbuild":null,"remaining":0,"result":"passed"}',
    "job done (passed) triggers fedmsg"
);
is(
    $args[1],
    $commonci
      . ' --topic=productmd-compose.test.complete --json-input --message='
      . '{"body":{"artifact":{"id":"Fedora-Rawhide-20180129.n.0","iso":"whatever.iso","issuer":"releng","type":"productmd-compose"},"category":"validation",'
      . '"ci":{"email":"qa-devel@lists.fedoraproject.org","irc":"#fedora-qa","name":"Fedora openQA","team":"Fedora QA",'
      . '"url":"https://openqa.stg.fedoraproject.org"},"run":{"id":'
      . $newerjob . ','
      . '"log":"https://openqa.stg.fedoraproject.org/tests/'
      . $newerjob
      . '/file/autoinst-log.txt",'
      . '"url":"https://openqa.stg.fedoraproject.org/tests/'
      . $newerjob . '"},'
      . '"status":"passed","type":"rainbow RainbowPC pink x86_64"},'
      . '"headers":{"id":"Fedora-Rawhide-20180129.n.0","type":"productmd-compose"}}',
    "job done (passed) triggers standardized fedmsg"
);
# reset $args
@args = ();

# FIXME: deleting job via DELETE call to api/v1/jobs/$newjob fails with 500?

# add a job comment via API
$t->post_ok("/api/v1/jobs/$job/comments" => form => {text => "test comment"})->status_is(200);
# stash the comment ID
my $comment = $t->tx->res->json->{id};
# check plugin called fedmsg-logger-3 correctly
my $dateexpr = '\d{4}-\d{1,2}-\d{1,2}T\d{2}:\d{2}:\d{2}Z';
like(
    $args[0],
qr/$commonexpr --topic=comment.create --json-input --message=\{"created":"$dateexpr","group_id":null,"id":$comment,"job_id":$job,"text":"test comment","updated":"$dateexpr","user":"perci"\}/,
    'comment post triggers fedmsg'
);
# reset $args
@args = ();

# update job comment via API
$t->put_ok("/api/v1/jobs/$job/comments/$comment" => form => {text => "updated comment"})->status_is(200);
# check plugin called fedmsg-logger-3 correctly
like(
    $args[0],
qr/$commonexpr --topic=comment.update --json-input --message=\{"created":"$dateexpr","group_id":null,"id":$comment,"job_id":$job,"text":"updated comment","updated":"$dateexpr","user":"perci"\}/,
    'comment update triggers fedmsg'
);
# reset $args
@args = ();

# become admin (so we can delete the comment)
$t->ua(OpenQA::Client->new(apikey => 'ARTHURKEY01', apisecret => 'EXCALIBUR')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);
# delete comment via API
$t->delete_ok("/api/v1/jobs/$job/comments/$comment")->status_is(200);
like(
    $args[0],
qr/$commonexpr --topic=comment.delete --json-input --message=\{"created":"$dateexpr","group_id":null,"id":$comment,"job_id":$job,"text":"updated comment","updated":"$dateexpr","user":"perci"\}/,
    'comment delete triggers fedmsg'
);
# reset $args
@args = ();

# create another job via API, this time for an update
$settings->{BUILD} = 'Update-FEDORA-2018-3c876babb9';
delete $settings->{ISO};
$t->post_ok("/api/v1/jobs" => form => $settings)->status_is(200);
my $updatejob = $t->tx->res->json->{id};
is(
    $args[0],
    $commonexpr
      . ' --topic=job.create --json-input --message='
      . '{"ARCH":"x86_64","BUILD":"Update-FEDORA-2018-3c876babb9","DESKTOP":"DESKTOP","DISTRI":"Unicorn","FLAVOR":"pink",'
      . '"ISO_MAXSIZE":"1","KVM":"KVM","MACHINE":"RainbowPC","TEST":"rainbow","VERSION":"42","id":'
      . $updatejob
      . ',"remaining":1}',
    "update job create triggers fedmsg"
);
is(
    $args[1],
    $commonci
      . ' --topic=fedora-update.test.queued --json-input --message='
      . '{"body":{"artifact":{"id":"FEDORA-2018-3c876babb9","issuer":"unknown","release":"42","type":"fedora-update"},"category":"validation",'
      . '"ci":{"email":"qa-devel@lists.fedoraproject.org","irc":"#fedora-qa","name":"Fedora openQA","team":"Fedora QA",'
      . '"url":"https://openqa.stg.fedoraproject.org"},"lifetime":240,"run":{"id":'
      . $updatejob . ','
      . '"log":"https://openqa.stg.fedoraproject.org/tests/'
      . $updatejob
      . '/file/autoinst-log.txt",'
      . '"url":"https://openqa.stg.fedoraproject.org/tests/'
      . $updatejob . '"},'
      . '"type":"rainbow RainbowPC pink x86_64"},'
      . '"headers":{"id":"FEDORA-2018-3c876babb9","type":"fedora-update"}}',
    "update job create triggers standardized fedmsg"
);
# reset $args
@args = ();

done_testing();
