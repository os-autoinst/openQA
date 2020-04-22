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
# with this program; if not, see <http://www.gnu.org/licenses/>.

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib";
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

OpenQA::Test::Case->new->init_data;

my $fake_server_port = Mojo::IOLoop::Server->generate_port;

$ENV{OPENQA_CONFIG} = my $tempdir = tempdir;
my $home_template = path(__FILE__)->dirname->dirname->child('data', 'openqa-trigger-from-obs');
my $home          = "$tempdir/openqa-trigger-from-obs";
dircopy($home_template, $home);
my $url = "http://127.0.0.1:$fake_server_port/public/build/%%PROJECT/_result";

$tempdir->child('openqa.ini')->spurt(<<"EOF");
[global]
plugins=ObsRsync
[obs_rsync]
home=$home
project_status_url=$url
EOF

note("Starting WebAPI");
my $t      = Test::Mojo->new('OpenQA::WebAPI');
my $helper = $t->app->obs_rsync;

# Allow Devel::Cover to collect stats for background jobs
$t->app->minion->on(
    worker => sub {
        my ($minion, $worker) = @_;
        $worker->on(
            dequeue => sub {
                my ($worker, $job) = @_;
                $job->on(cleanup => sub { Devel::Cover::report() if Devel::Cover->can('report') });
            });
    });


my %fake_response_by_project = (
    Proj3 => '
<!-- This project is published. -->
<resultlist state="c181538ad4f4c1be29e73f85b9237653">
  <result project="Proj3" repository="standard" arch="i586" code="published" state="published">
    <status package="000product" code="excluded"/>
  </result>
  <result project="Proj3" repository="standard" arch="x86_64" code="published" state="published">
    <status package="000product" code="excluded"/>
  </result>
  <result project="Proj3" repository="images" arch="local" code="unpublished" state="unpublished">
    <status package="000product" code="disabled"/>
  </result>
  <result project="Proj3" repository="images" arch="i586" code="unpublished" state="unpublished">
    <status package="000product" code="disabled"/>
  </result>
  <result project="Proj3" repository="images" arch="x86_64" code="unpublished" state="unpublished">
    <status package="000product" code="disabled"/>
  </result>
</resultlist>',
    Proj2 => '
<!-- This project is still being published. -->
<resultlist state="c181538ad4f4c1be29e73f85b9237651">
  <result project="Proj2" repository="standard" arch="i586" code="unpublished" state="unpublished">
    <status package="000product" code="excluded"/>
  </result>
  <result project="Proj2" repository="standard" arch="x86_64" code="unpublished" state="unpublished">
    <status package="000product" code="excluded"/>
  </result>
  <result project="Proj2" repository="images" arch="local" code="ready" state="publishing">
    <status package="000product" code="disabled"/>
  </result>
  <result project="Proj2" repository="images" arch="i586" code="published" state="published">
    <status package="000product" code="disabled"/>
  </result>
  <result project="Proj2" repository="images" arch="x86_64" code="published" state="published">
    <status package="000product" code="disabled"/>
  </result>
</resultlist>',
    Proj1 => '
<!-- This project is "dirty". -->
<resultlist state="c181538ad4f4c1be29e73f85b9237653">
  <result project="Proj1" repository="standard" arch="x86_64" code="published" state="published" dirty>
    <status package="000product" code="disabled"/>
  </result>
</resultlist>',
    Proj0 => 'invalid XML',
);

$SIG{INT} = sub {
    session->clean;
};

END { session->clean }

my $host = "http://127.0.0.1:$fake_server_port";

sub fake_api_server {
    my $mock = Mojolicious->new;
    $mock->mode('test');
    for my $project (sort keys %fake_response_by_project) {
        ($project, undef, undef) = $helper->split_alias($project);
        $mock->routes->get(
            "/public/build/$project/_result" => sub {
                my $c   = shift;
                my $pkg = $c->param('package');
                return $c->render(status => 404) if !$pkg and $project ne "Proj1";
                return $c->render(status => 200, text => $fake_response_by_project{$project});
            });
    }
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
    sleep 1 while !_port($fake_server_port);
    return;
}

sub stop_server {
    # now kill the worker
    $server_instance->stop();
}

note("Starting fake api server");
start_server();

subtest 'test api repo helper' => sub {
    is($helper->get_api_repo('Proj1'),             'standard');
    is($helper->get_api_repo('Proj1::appliances'), 'appliances');
    is($helper->get_api_repo('Proj2'),             'images');
    is($helper->get_api_repo('BatchedProj'),       'containers');
};

subtest 'test api package helper' => sub {
    is($helper->get_api_package('Proj1'),       '');
    is($helper->get_api_package('Proj2'),       '0product');
    is($helper->get_api_package('BatchedProj'), '000product');
};

subtest 'test api url helper' => sub {
    is($helper->get_api_dirty_status_url('Proj1'), "http://127.0.0.1:$fake_server_port/public/build/Proj1/_result");
    is($helper->get_api_dirty_status_url('Proj2'),
        "http://127.0.0.1:$fake_server_port/public/build/Proj2/_result?package=0product");
    is($helper->get_api_dirty_status_url('BatchedProj'),
        "http://127.0.0.1:$fake_server_port/public/build/BatchedProj/_result?package=000product");
};

subtest 'test builds_text helper' => sub {
    is($helper->get_obs_builds_text('Proj1',              1), '470.1');
    is($helper->get_obs_builds_text('BatchedProj',        1), '4704, 4703, 470.2, 469.1');
    is($helper->get_obs_builds_text('BatchedProj|Batch1', 1), '470.2, 469.1');
    is($helper->get_obs_builds_text('BatchedProj|Batch2', 1), '4704, 4703');
};

subtest 'test status_dirty helper' => sub {
    is($helper->is_status_dirty('Proj0'),           undef, 'status unknown');
    is($helper->is_status_dirty('Proj1'),           1,     'status dirty');
    is($helper->is_status_dirty('Proj2'),           1,     'status publishing');
    is($helper->is_status_dirty('Proj3'),           0,     'status unpublished');
    is($helper->is_status_dirty('Proj3::standard'), 0,     'status published');
};

$t->get_ok('/');
my $token = $t->tx->res->dom->at('meta[name=csrf-token]')->attr('content');
# needs to log in (it gets redirected)
$t->get_ok('/login');
BAIL_OUT('Login exit code (' . $t->tx->res->code . ')') if $t->tx->res->code != 302;

# no inactive gru jobs is dispayed in project list
$t->get_ok('/admin/obs_rsync/')->status_is(200, 'project list')->content_unlike(qr/inactive/);

$t->post_ok('/admin/obs_rsync/Proj1/runs' => {'X-CSRF-Token' => $token})->status_is(201, 'trigger rsync');
$t->post_ok('/admin/obs_rsync/Proj2/runs' => {'X-CSRF-Token' => $token})->status_is(201, 'trigger rsync');
$t->post_ok('/admin/obs_rsync/Proj3/runs?repository=standard' => {'X-CSRF-Token' => $token})
  ->status_is(201, 'trigger rsync');

# now inactive job is dispayed in project list
$t->get_ok('/admin/obs_rsync/')->status_is(200, 'project list')->content_like(qr/inactive/);

# at start job is added as inactive
$t->get_ok('/admin/obs_rsync/queue')->status_is(200, 'jobs list')->content_like(qr/inactive/)
  ->content_unlike(qr/\bactive\b/)->content_like(qr/Proj1/)->content_like(qr/Proj2/)->content_like(qr/Proj3/);

$t->app->minion->perform_jobs;

# Proj1 and Proj2 must be still in queue, but Proj3 must gone now
$t->get_ok('/admin/obs_rsync/queue')->status_is(200, 'jobs list')->content_like(qr/inactive/)
  ->content_unlike(qr/\bactive\b/)->content_like(qr/Proj1/)->content_like(qr/Proj2/)->content_unlike(qr/Proj3/);

$t->get_ok('/admin/obs_rsync/')->status_is(200, 'project list')->content_like(qr/published/)->content_like(qr/dirty/)
  ->content_like(qr/publishing/);

stop_server();
done_testing();
