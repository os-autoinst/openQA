# Copyright 2019-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '30';
use OpenQA::Test::Utils qw(perform_minion_jobs wait_for_or_bail_out);
use OpenQA::Test::ObsRsync 'setup_obs_rsync_test';

use Mojolicious;
use IO::Socket::INET;
use Mojo::Server::Daemon;
use Mojo::IOLoop::Server;
use Mojo::IOLoop::ReadWriteProcess 'process';
use Mojo::IOLoop::ReadWriteProcess::Session 'session';

$SIG{INT} = sub { session->clean };
END { session->clean }

my $port = Mojo::IOLoop::Server->generate_port;
my $host = "http://127.0.0.1:$port";
my $url = "$host/public/build/%%PROJECT/_result";
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

note 'Starting fake API server';
my $server_instance = process sub {
    my $mock = Mojolicious->new;
    $mock->mode('test');
    for my $project (sort keys %fake_response_by_project) {
        $mock->routes->get(
            "/public/build/$project/_result" => sub {
                my $c = shift;
                my $pkg = $c->param('package');
                return $c->render(status => 404) if !$pkg and $project ne 'Proj1';
                return $c->render(status => 200, text => $fake_response_by_project{$project});
            });
    }
    my $daemon = Mojo::Server::Daemon->new(app => $mock, listen => [$host]);
    $daemon->run;
    note 'Fake API server stopped';
    _exit(0);
};
$server_instance->set_pipes(0)->start;
wait_for_or_bail_out { IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port) } 'API';

my ($t, $tempdir, $home, $params) = setup_obs_rsync_test(url => $url);
my $app = $t->app;
my $helper = $app->obs_rsync;

subtest 'test api repo helper' => sub {
    is($helper->get_api_repo('Proj1'), 'standard');
    is($helper->get_api_repo('Proj1::appliances'), 'appliances');
    is($helper->get_api_repo('Proj2'), 'images');
    is($helper->get_api_repo('BatchedProj'), 'containers');
};

subtest 'test api package helper' => sub {
    is($helper->get_api_package('Proj1'), '');
    is($helper->get_api_package('Proj2'), '0product');
    is($helper->get_api_package('BatchedProj'), '000product');
};

subtest 'test api url helper' => sub {
    is($helper->get_api_dirty_status_url('Proj1'), "$host/public/build/Proj1/_result");
    is($helper->get_api_dirty_status_url('Proj2'), "$host/public/build/Proj2/_result?package=0product");
    is($helper->get_api_dirty_status_url('BatchedProj'), "$host/public/build/BatchedProj/_result?package=000product");
};

subtest 'test builds_text helper' => sub {
    is($helper->get_obs_builds_text('Proj1', 1), '470.1');
    is($helper->get_obs_builds_text('BatchedProj', 1), '4704, 4703, 470.2, 469.1');
    is($helper->get_obs_builds_text('BatchedProj|Batch1', 1), '470.2, 469.1');
    is($helper->get_obs_builds_text('BatchedProj|Batch2', 1), '4704, 4703');
};

subtest 'test status_dirty helper' => sub {
    is($helper->is_status_dirty('Proj0'), undef, 'status unknown');
    is($helper->is_status_dirty('Proj1'), 1, 'status dirty');
    is($helper->is_status_dirty('Proj2'), 1, 'status publishing');
    is($helper->is_status_dirty('Proj3'), 0, 'status unpublished');
    is($helper->is_status_dirty('Proj3::standard'), 0, 'status published');
};

# no inactive gru jobs is displayed in project list
$t->get_ok('/admin/obs_rsync/')->status_is(200, 'project list')->content_unlike(qr/inactive/);

$t->post_ok('/admin/obs_rsync/Proj1/runs' => $params)->status_is(201, 'trigger rsync (1)');
$t->post_ok('/admin/obs_rsync/Proj2/runs' => $params)->status_is(201, 'trigger rsync (2)');
$t->post_ok('/admin/obs_rsync/Proj3/runs?repository=standard' => $params)->status_is(201, 'trigger rsync (3)');

# now inactive job is displayed in project list
$t->get_ok('/admin/obs_rsync/')->status_is(200, 'project list')->content_like(qr/inactive/);

# at start job is added as inactive
$t->get_ok('/admin/obs_rsync/queue')->status_is(200, 'jobs list')->content_like(qr/inactive/)
  ->content_unlike(qr/\bactive\b/)->content_like(qr/Proj1/)->content_like(qr/Proj2/)->content_like(qr/Proj3/);

perform_minion_jobs($t->app->minion);

# Proj1 and Proj2 must be still in queue, but Proj3 must gone now
$t->get_ok('/admin/obs_rsync/queue')->status_is(200, 'jobs list')->content_like(qr/inactive/)
  ->content_unlike(qr/\bactive\b/)->content_like(qr/Proj1/)->content_like(qr/Proj2/)->content_unlike(qr/Proj3/);

$t->get_ok('/admin/obs_rsync/')->status_is(200, 'project list')->content_like(qr/published/)->content_like(qr/dirty/)
  ->content_like(qr/publishing/);

$server_instance->stop;
done_testing();
