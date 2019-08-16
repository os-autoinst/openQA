# Copyright (C) 2019 SUSE LLC
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

use Mojo::Base -strict;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::Most;
use Test::Mojo;
use OpenQA::Test::Database;
use OpenQA::Test::Case;
use Mojo::File qw(tempdir path);

use Mojolicious;
use IO::Socket::INET;
use Mojo::Server::Daemon;
use Mojo::IOLoop::Server;
use Mojo::IOLoop::ReadWriteProcess qw(process);
use Mojo::IOLoop::ReadWriteProcess::Session 'session';

OpenQA::Test::Case->new->init_data;

my $response_published = '<resultlist state="c181538ad4f4c1be29e73f85b9237653">
  <result project="Proj1" repository="standard" arch="i586" code="unpublished" state="unpublished">
    <status package="000product" code="excluded"/>
  </result>
  <result project="Proj1" repository="standard" arch="x86_64" code="unpublished" state="unpublished">
    <status package="000product" code="excluded"/>
  </result>
  <result project="Proj1" repository="images" arch="local" code="published" state="published">
    <status package="000product" code="disabled"/>
  </result>
  <result project="Proj1" repository="images" arch="i586" code="published" state="published">
    <status package="000product" code="disabled"/>
  </result>
  <result project="Proj1" repository="images" arch="x86_64" code="published" state="published">
    <status package="000product" code="disabled"/>
  </result>
</resultlist>';

my $response_publishing = '<resultlist state="c181538ad4f4c1be29e73f85b9237651">
  <result project="Proj1" repository="standard" arch="i586" code="unpublished" state="unpublished">
    <status package="000product" code="excluded"/>
  </result>
  <result project="Proj1" repository="standard" arch="x86_64" code="unpublished" state="unpublished">
    <status package="000product" code="excluded"/>
  </result>
  <result project="Proj1" repository="images" arch="local" code="ready" state="publishing">
    <status package="000product" code="disabled"/>
  </result>
  <result project="Proj1" repository="images" arch="i586" code="published" state="published">
    <status package="000product" code="disabled"/>
  </result>
  <result project="Proj1" repository="images" arch="x86_64" code="published" state="published">
    <status package="000product" code="disabled"/>
  </result>
</resultlist>';

my $response_dirty = 'dirty';
our $response;

$SIG{INT} = sub {
    session->clean;
};

END { session->clean }

my $port = Mojo::IOLoop::Server->generate_port;
my $host = "http://127.0.0.1:$port";

sub fake_api_server {
    my $mock = Mojolicious->new;
    $mock->mode('test');
    $mock->routes->get(
        '/public/build/Proj1/_result' => sub {
            my $c = shift;
            return $c->render(status => 200, text => $response_dirty);
        });
    $mock->routes->get(
        '/public/build/Proj2/_result' => sub {
            my $c = shift;
            return $c->render(status => 200, text => $response_publishing);
        });
    $mock->routes->get(
        '/public/build/Proj3/_result' => sub {
            my $c = shift;
            return $c->render(status => 200, text => $response_published);
        });


    return $mock;
}

sub _port { IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => shift) }

my $daemon;
my $mock            = Mojolicious->new;
my $server_instance = process sub {
    $daemon = Mojo::Server::Daemon->new(app => fake_api_server, listen => [$host]);
    $daemon->run;
    _exit(0);
};

sub start_server {
    $server_instance->set_pipes(0)->start;
    sleep 1 while !_port($port);
    return;
}

sub stop_server {
    # now kill the worker
    $server_instance->stop();
}

$ENV{OPENQA_CONFIG} = my $tempdir = tempdir;
my $home = path(__FILE__)->dirname->dirname->child('data', 'openqa-trigger-from-obs');
my $url  = "http://127.0.0.1:$port/public/build/%%PROJECT/_result?package=000product";

$tempdir->child('openqa.ini')->spurt(<<"EOF");
[global]
plugins=ObsRsync
[obs_rsync]
home=$home
project_status_url=$url
EOF

print "Starting fake api server\n";
start_server();

print "Starting WebAPI\n";
my $t = Test::Mojo->new('OpenQA::WebAPI');

bail_on_fail;

subtest 'test helper directly' => sub {
    my $res = $t->app->obs_project->is_status_dirty('Proj1');
    ok($res, "Status dirty");

    $res = $t->app->obs_project->is_status_dirty('Proj2');
    ok($res, "Status publishing $res");

    $res = $t->app->obs_project->is_status_dirty('Proj3');
    ok(!$res, "Status published $res");
};

$t->get_ok('/');
my $token = $t->tx->res->dom->at('meta[name=csrf-token]')->attr('content');
# needs to log in (it gets redirected)
$t->get_ok('/login');

$t->post_ok('/admin/obs_rsync/Proj1/runs' => {'X-CSRF-Token' => $token})->status_is(201, "trigger rsync");
$t->post_ok('/admin/obs_rsync/Proj2/runs' => {'X-CSRF-Token' => $token})->status_is(201, "trigger rsync");
$t->post_ok('/admin/obs_rsync/Proj3/runs' => {'X-CSRF-Token' => $token})->status_is(201, "trigger rsync");

# at start job is added as inactive
$t->get_ok('/admin/obs_rsync/queue')->status_is(200, "jobs list")->content_like(qr/inactive/)
  ->content_unlike(qr/\bactive\b/)->content_like(qr/Proj1/)->content_like(qr/Proj2/)->content_like(qr/Proj3/);

$t->app->start('gru', 'run', '--oneshot');

# Proj1 and Proj2 must be still there but Proj3 must gone now
$t->get_ok('/admin/obs_rsync/queue')->status_is(200, "jobs list")->content_like(qr/inactive/)
  ->content_unlike(qr/\bactive\b/)->content_like(qr/Proj1/)->content_like(qr/Proj2/)->content_unlike(qr/Proj3/);

stop_server();
done_testing();
