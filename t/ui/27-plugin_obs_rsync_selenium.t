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
use Test::More;
use Test::Mojo;
use OpenQA::Test::Database;
use OpenQA::Test::Case;
use Mojo::File qw(tempdir path);
use File::Copy::Recursive 'dircopy';

use Mojolicious;
use IO::Socket::INET;
use Mojo::Server::Daemon;
use Mojo::IOLoop::Server;
use Mojo::IOLoop::ReadWriteProcess qw(process);
use Mojo::IOLoop::ReadWriteProcess::Session 'session';
use Time::HiRes 'sleep';

my $test_case   = OpenQA::Test::Case->new;
my $schema_name = OpenQA::Test::Database->generate_schema_name;
my $schema      = $test_case->init_data(schema_name => $schema_name);

use OpenQA::SeleniumTest;

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
        "/public/build/Proj1/_result" => sub {
            shift->render(
                status => 200,
                text   => '<result project="Proj1" repository="images" arch="local" code="published" state="published">'
            );
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
    sleep 0.1 while !_port($port);
    return;
}

sub stop_server {
    # now kill the worker
    $server_instance->stop();
}

$ENV{OPENQA_CONFIG} = my $tempdir = tempdir;
my $home_template = path(__FILE__)->dirname->dirname->child('data', 'openqa-trigger-from-obs');
my $home          = "$tempdir/openqa-trigger-from-obs";
dircopy($home_template, $home);
my $url = "http://127.0.0.1:$port/public/build/%%PROJECT/_result?package=000product";

$tempdir->child('openqa.ini')->spurt(<<"EOF");
[global]
plugins=ObsRsync
[obs_rsync]
home=$home
project_status_url=$url
EOF

note("Starting fake api server");
start_server();

my $driver = call_driver(sub { }, {with_gru => 1});

plan skip_all => $OpenQA::SeleniumTest::drivermissing unless $driver;

$driver->find_element_by_class('navbar-brand')->click();
$driver->find_element_by_link_text('Login')->click();

$driver->get('/admin/obs_rsync/');

is($driver->find_element('tr#folder_Proj1 .project')->get_text(), 'Proj1', 'Proj1 name');
ok(index($driver->find_element('tr#folder_Proj1 .lastsync')->get_text(), '190703_143010') != -1, 'Proj1 last sync');
is($driver->find_element('tr#folder_Proj1 .lastsyncversion')->get_text(), '470.1', 'Proj1 sync version');
# at start no project fetches version from obs
is($driver->find_element('tr#folder_Proj1 .obsversion')->get_text(), '', 'Proj1 obs version empty');
ok(index($driver->find_element('tr#folder_Proj1 .dirtystatuscol .dirtystatus')->get_text(), 'dirty') != -1,
    'Proj1 dirty status');

# now request fetching version from obs
$driver->find_element('tr#folder_Proj1 .obsversionupdate')->click();
my $retries = 50;
my $obsversion;
while ($retries > 0) {
    $obsversion = $driver->find_element('tr#folder_Proj1 .obsversion')->get_text();
    last if $obsversion;
    sleep(0.1);
    $retries = $retries - 1;
}

is($driver->find_element('tr#folder_Proj1 .obsversion')->get_text(), '470.1', 'Proj1 obs version');

# now we call forget_run_last() and refresh_last_run() and check once again corresponding columns
$driver->find_element('tr#folder_Proj1 .lastsyncforget')->click();
$driver->accept_alert;

$retries = 50;
my $lastsync;
while ($retries > 0) {
    $lastsync = $driver->find_element('tr#folder_Proj1 .lastsync')->get_text();
    last if !$lastsync;
    sleep(0.1);
    $retries = $retries - 1;
}

ok(index($driver->find_element('tr#folder_Proj1 .lastsync')->get_text(), '190703_143010') == -1,
    'Proj1 last sync forgotten');
is($lastsync, '', 'Proj1 last sync forgotten');

$driver->get('/admin/obs_rsync/');
is($driver->find_element('tr#folder_Proj1 .lastsync')->get_text(), 'no data', 'Proj1 last sync forgotten');

$driver->find_element('tr#folder_Proj1 .dirtystatusupdate')->click();
# now wait until gru picks the task up
$retries = 5;
my $dirty_status;
while ($retries > 0) {
    $dirty_status = $driver->find_element('tr#folder_Proj1 .dirtystatuscol .dirtystatus')->get_text();
    last if index($dirty_status, 'dirty') == -1;
    sleep(1);
    $retries = $retries - 1;
}

ok(index($dirty_status, 'dirty') == -1,     'Proj1 dirty status is not dirty anymore');
ok(index($dirty_status, 'published') != -1, 'Proj1 dirty is published');

# click once again and make sure that timestamp on status changed
$driver->find_element('tr#folder_Proj1 .dirtystatusupdate')->click();
$retries = 5;
my $new_dirty_status;
while ($retries > 0) {
    $driver->get('/admin/obs_rsync/');
    $new_dirty_status = $driver->find_element('tr#folder_Proj1 .dirtystatuscol .dirtystatus')->get_text();
    last if $dirty_status ne $new_dirty_status;
    sleep(1);
    $retries = $retries - 1;
}

isnt($dirty_status, $new_dirty_status, 'Timestamp on dirty status is updated');

stop_server();
kill_driver();
done_testing();
