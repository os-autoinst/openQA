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
use Mojo::File qw(path tempfile);

my $mocked_time = 0;

BEGIN {
    *CORE::GLOBAL::time = sub {
        return $mocked_time if $mocked_time;
        return time();
    };
}

$SIG{INT} = sub { session->clean };    # uncoverable statement count:2

END { session->clean }

my $port = Mojo::IOLoop::Server->generate_port;
my $host = "http://127.0.0.1:$port";
my $url = "$host/build/%%PROJECT/_result";
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

my $auth_header_exact
  = q(Signature keyId="dummy-username",algorithm="ssh",)
  . q(signature="U1NIU0lHAAAAAQAAADMAAAALc3NoLWVkMjU1MTkAAAAgSKpcECPm8Vjo9UznZS+)
  . q(M/QLjmXXmLzoBxkIbZ8Z/oPkAAAAaVXNlIHlvdXIgZGV2ZWxvcGVyIGFjY291bnQAAAAAAAAABn)
  . q(NoYTUxMgAAAFMAAAALc3NoLWVkMjU1MTkAAABA8cmvTy1PgpW2XhHWxQ1yw/wPGAfT2M3CGRJ3II)
  . q(7uT5Orqn1a0bWlo/lEV0WiqP+pPcQdajQ4a2YGJvpfzT1uBA==",)
  . q(headers="(created)",created="1664187470");

note 'Starting fake API server';

my $server_process = sub {
    use experimental 'signatures';
    my $mock = Mojolicious->new;
    $mock->mode('test');

    my $www_authenticate = q(Signature realm="Use your developer account",headers="(created)");
    $mock->routes->get(
        '/build/ProjWithAuth/_result' => sub ($c) {
            return $c->render(status => 200, text => $fake_response_by_project{Proj1})
              if $c->req->headers->authorization;
            $c->res->headers->www_authenticate($www_authenticate);
            return $c->render(status => 401, text => 'login');
        });

    $mock->routes->get(
        '/build/ProjTestingSignature/_result' => sub ($c) {
            my $client_auth_header = $c->req->headers->authorization // '';
            return $c->render(status => 200, text => $fake_response_by_project{Proj1})
              if $auth_header_exact eq $client_auth_header;
            $c->res->headers->www_authenticate($www_authenticate);
            return $c->render(status => 401, text => 'login');
        });

    for my $project (sort keys %fake_response_by_project) {
        $mock->routes->get(
            "/build/$project/_result" => sub ($c) {
                my $pkg = $c->param('package');
                return $c->render(status => 404) if !$pkg and $project ne 'Proj1';
                return $c->render(status => 200, text => $fake_response_by_project{$project});
            });
    }
    my $daemon = Mojo::Server::Daemon->new(app => $mock, listen => [$host]);
    $daemon->run;
    note 'Fake API server stopped';
    Devel::Cover::report() if Devel::Cover->can('report');
    _exit(0);    # uncoverable statement
};

my $server_instance = process(
    $server_process,
    max_kill_attempts => 0,
    blocking_stop => 1,
    _default_blocking_signal => POSIX::SIGTERM,
    kill_sleeptime => 0
);

$server_instance->set_pipes(0)->start;
wait_for_or_bail_out { IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port) } 'API';

my $ssh_keyfile = tempfile("$FindBin::Script-sshkey-XXXXX");
# using the key from [0] to have a reproduceable output.
$ssh_keyfile->spew(<<EOF);
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACBIqlwQI+bxWOj1TOdlL4z9AuOZdeYvOgHGQhtnxn+g+QAAAJiRS1EekUtR
HgAAAAtzc2gtZWQyNTUxOQAAACBIqlwQI+bxWOj1TOdlL4z9AuOZdeYvOgHGQhtnxn+g+Q
AAAECrZDKH46WiRLiazilOn4+BlnESdV8CNReMvlm2Pr6Yr0iqXBAj5vFY6PVM52UvjP0C
45l15i86AcZCG2fGf6D5AAAAE3NhbXBsZS1tZmEtZmxvd0BpYnMBAg==
-----END OPENSSH PRIVATE KEY-----
EOF


my ($t, $tempdir, $home, $params) = setup_obs_rsync_test(
    url => $url,
    config => {
        username => 'dummy-username',
        ssh_key_file => path($ssh_keyfile),
    });
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
    is($helper->get_api_dirty_status_url('Proj1'), "$host/build/Proj1/_result");
    is($helper->get_api_dirty_status_url('Proj2'), "$host/build/Proj2/_result?package=0product");
    is($helper->get_api_dirty_status_url('BatchedProj'), "$host/build/BatchedProj/_result?package=000product");
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

subtest 'build service ssh authentication' => sub {
    is($helper->is_status_dirty('ProjWithAuth'), 1, 're-authenticate with ssh auth');
};

subtest 'build service authentication: signature generation' => sub {
    $mocked_time = 1664187470;
    note 'time right now: ' . time();
    is(time(), $mocked_time, 'Time is not frozen!');
    is($helper->is_status_dirty('ProjTestingSignature'), 1, 'signature matches fixture');
    $mocked_time = undef;
};

subtest 'build service authentication: error handling' => sub {
    $ssh_keyfile->remove();
    throws_ok {
        $helper->is_status_dirty('ProjTestingSignature')
    }
    qr/SSH key file not found at/, 'Key detection logic failed (not existing key file)';

    path($ssh_keyfile)->touch();
    throws_ok {
        $helper->is_status_dirty('ProjTestingSignature')
    }
    qr/SSH key file not found at/, 'Key detection logic failed (empty key file)';
};

$server_instance->stop;
done_testing();

# [0]: https://www.suse.com/c/multi-factor-authentication-on-suses-build-service/
