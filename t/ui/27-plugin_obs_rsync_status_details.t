# Copyright (C) 2019-2021 SUSE LLC
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
use Mojo::Base -signatures;
use Test::Warnings;
use Test::Mojo;
use OpenQA::Test::TimeLimit '60';
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

my $port          = Mojo::IOLoop::Server->generate_port;
my $host          = "http://127.0.0.1:$port";
my $url           = "$host/public/build/%%PROJECT/_result";
my $tempdir       = tempdir;
my $home_template = path(__FILE__)->dirname->dirname->child('data', 'openqa-trigger-from-obs');
my $home          = "$tempdir/openqa-trigger-from-obs";
my $test_case     = OpenQA::Test::Case->new(config_directory => $tempdir);

$tempdir->child('openqa.ini')->spurt(<<"EOF");
[global]
plugins=ObsRsync
[obs_rsync]
home=$home
project_status_url=$url
EOF

my $schema_name = OpenQA::Test::Database->generate_schema_name;
my $schema      = $test_case->init_data(schema_name => $schema_name, fixtures_glob => '01-jobs.pl 03-users.pl');
my $t           = Test::Mojo->new('OpenQA::WebAPI');
END { session->clean }
plan skip_all => $OpenQA::SeleniumTest::drivermissing unless my $driver = call_driver({with_gru => 1});

$driver->find_element_by_class('navbar-brand')->click();
$driver->find_element_by_link_text('Login')->click();

my %params = (
    'Proj1'             => ['190703_143010', 'standard',   '',            '470.1', 99937, 'passed'],
    'Proj2::appliances' => ['no data',       'appliances', '',            ''],
    'BatchedProj'       => ['191216_150610', 'containers', '',            '4704, 4703, 470.2, 469.1'],
    'Batch1'            => ['191216_150610', 'containers', 'BatchedProj', '470.2, 469.1'],
);

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
}

done_testing();
