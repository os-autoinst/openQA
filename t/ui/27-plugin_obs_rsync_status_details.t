# Copyright (C) 2019-2020 SUSE LLC
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
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Warnings;
use Test::Mojo;
use OpenQA::Test::TimeLimit '50';
use OpenQA::Test::Database;
use OpenQA::Test::Case;
use OpenQA::Test::Utils 'wait_for_or_bail_out';
use OpenQA::SeleniumTest;
use Mojo::File qw(tempdir path);
use File::Copy::Recursive 'dircopy';

use Mojolicious;
use IO::Socket::INET;
use Mojo::Server::Daemon;
use Mojo::IOLoop::Server;
use Mojo::IOLoop::ReadWriteProcess 'process';
use Mojo::IOLoop::ReadWriteProcess::Session 'session';
use Time::HiRes 'sleep';

OpenQA::Test::Case->new->init_data();

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
        '/public/build/:proj/_result' => sub {
            my $c       = shift;
            my $proj    = $c->stash('proj');
            my $package = $c->param('package') // '';
            return $c->render(
                status => 404,
                test   => 'unknown package'
            ) if $proj eq 'Proj2' && $package ne 'mypackage';
            my %repos = (
                'Proj1'       => 'standard',
                'Proj2'       => 'appliances',
                'BatchedProj' => 'containers',
            );
            my $repo = $repos{$proj};
            $repo = 'images' unless $repo;
            return $c->render(
                status => 200,
                text => qq{<result project="$proj" repository="$repo" arch="local" code="published" state="published">}
                  . qq{<result project="$proj" repository="images" arch="local" code="building" state="building">}
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
    wait_for_or_bail_out { _port($port) } 'worker';
}

sub stop_server {
    # now kill the worker
    $server_instance->stop();
}

my $url = "http://127.0.0.1:$port/public/build/%%PROJECT/_result";

$ENV{OPENQA_CONFIG} = my $tempdir = tempdir;
my $home_template = path(__FILE__)->dirname->dirname->child('data', 'openqa-trigger-from-obs');
my $home          = "$tempdir/openqa-trigger-from-obs";

$tempdir->child('openqa.ini')->spurt(<<"EOF");
[global]
plugins=ObsRsync
[obs_rsync]
home=$home
project_status_url=$url
EOF

note("Starting fake api server");
start_server();

plan skip_all => $OpenQA::SeleniumTest::drivermissing unless my $driver = call_driver({with_gru => 1});

$driver->find_element_by_class('navbar-brand')->click();
$driver->find_element_by_link_text('Login')->click();

my %params = (
    'Proj1'             => ['190703_143010', 'standard',   '',            '470.1', 99937, 'passed'],
    'Proj2::appliances' => ['no data',       'appliances', '',            ''],
    'BatchedProj'       => ['191216_150610', 'containers', '',            '4704, 4703, 470.2, 469.1'],
    'Batch1'            => ['191216_150610', 'containers', 'BatchedProj', '470.2, 469.1'],
);

sub _wait_helper {
    my ($element, $test_break) = @_;
    my $ret;
    for (0 .. 50) {
        $ret = $driver->find_element($element)->get_text();
        return $ret if $test_break->($ret);    # uncoverable statement
        sleep .1;                              # uncoverable statement
    }

    # sometimes gru is not fast enough, so let's refresh the page and see if that helped
    $driver->refresh();                        # uncoverable statement
    for (0 .. 5) {                             # uncoverable statement
        $ret = $driver->find_element($element)->get_text();    # uncoverable statement
        return $ret if $test_break->($ret);                    # uncoverable statement
        sleep .1;                                              # uncoverable statement
    }
    return $ret;                                               # uncoverable statement
}

foreach my $proj (sort keys %params) {
    my $ident = $proj;
    # remove special characters to refer UI, the same way as in template
    $ident =~ s/\W//g;
    dircopy($home_template, $home);
    my ($dt, $repo, $parent, $builds_text, $test_id, $test_result) = @{$params{$proj}};

    $driver->get("/admin/obs_rsync/$parent");
    my $projfull = $proj;
    $projfull = "$parent|$proj" if $parent;

    # check project name and other fields are displayed properly
    is($driver->find_element("tr#folder_$ident .project")->get_text(), $projfull, "$proj name");
    like($driver->find_element("tr#folder_$ident .lastsync")->get_text(), qr/$dt/,          "$proj last sync");
    like($driver->find_element("tr#folder_$ident .testlink")->get_text(), qr/$test_result/, "$proj last test result")
      if $test_result;
    is($driver->find_element("tr#folder_$ident .lastsyncbuilds")->get_text(), $builds_text, "$proj sync builds");

    # at start no project fetches builds from obs
    is($driver->find_element("tr#folder_$ident .obsbuilds")->get_text(), '', "$proj obs builds empty");
    my $status = $driver->find_element("tr#folder_$ident .dirtystatuscol .dirtystatus")->get_text();
    like($status, qr/dirty/, "$proj dirty status");
    like($status, qr/$repo/, "$proj repo in dirty status ($status)");
    like($status, qr/$repo/, "$proj dirty has repo");

    # the following code is unreliable without relying on a longer timeout in
    # the web driver as the timing behaviour of background tasks has not been
    # mocked away
    enable_timeout;

    # now request fetching builds from obs
    $driver->find_element("tr#folder_$ident .obsbuildsupdate")->click();
    my $obsbuilds = _wait_helper("tr#folder_$ident .obsbuilds", sub { shift });
    is($obsbuilds, ($builds_text ? $builds_text : 'No data'), "$proj obs builds");

    if ($dt ne 'no data') {
        # now we call forget_run_last() and refresh_last_run() and check once again corresponding columns
        $driver->find_element("tr#folder_$ident .lastsyncforget")->click();
        $driver->accept_alert;

        my $lastsync = _wait_helper("tr#folder_$ident .lastsync", sub { my $v = shift; !$v || $v eq 'no data' });
        unlike($lastsync, qr/$dt/, "$proj last sync forgotten");
        is($lastsync, '', "$proj last sync is empty");

        # refresh page and make sure that last sync is gone
        $driver->get("/admin/obs_rsync/$parent");
        is($driver->find_element("tr#folder_$ident .lastsync")->get_text(),
            'no data', "$proj last sync absent from web UI");
    }
    # Update project status
    $driver->find_element("tr#folder_$ident .dirtystatusupdate")->click();
    # now wait until gru picks the task up
    my $dirty_status
      = _wait_helper("tr#folder_$ident .dirtystatuscol .dirtystatus", sub { index(shift, 'dirty') == -1 });

    unlike($dirty_status, qr/dirty/, "$proj dirty status is not dirty anymore");
    like($dirty_status, qr/published/, "$proj dirty is published");

    # click once again and make sure that timestamp on status changed
    $driver->find_element("tr#folder_$ident .dirtystatusupdate")->click();
    my $new_dirty_status
      = _wait_helper("tr#folder_$ident .dirtystatuscol .dirtystatus", sub { shift ne $dirty_status });
    isnt($dirty_status, $new_dirty_status, 'Timestamp on dirty status is updated');

    # Test that project page loads properly and has 'Sync Now', which redirects to jobs status page
    # (except BatchedProj, which will not have the button
    if ($proj ne 'BatchedProj') {
        # test 'Sync Now' button
        $driver->get("/admin/obs_rsync/$projfull");
        $driver->find_element_by_class('btn-warning')->click();
        wait_for_ajax();

        is($driver->get_title(), 'openQA: OBS synchronization jobs', 'Get redirected to obs gru jobs page');
    }
}

stop_server();
kill_driver();
done_testing();
