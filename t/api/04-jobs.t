# Copyright (C) 2015 SUSE Linux Products GmbH
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

BEGIN {
    unshift @INC, 'lib';
}

use Mojo::Base -strict;
use Test::More tests => 60;
use Test::Mojo;
use OpenQA::Test::Case;
use OpenQA::Client;
use Mojo::IOLoop;
use Digest::MD5;
use OpenQA::IPC;
use OpenQA::WebSockets;
use OpenQA::Scheduler;

# create Test DBus bus and service for fake WebSockets and Scheduler call
my $ipc = OpenQA::IPC->ipc('', 1);
my $ws  = OpenQA::WebSockets->new;
my $sh  = OpenQA::Scheduler->new;

sub calculate_file_md5($) {
    my ($file) = @_;
    my $c      = OpenQA::Utils::file_content($file);
    my $md5    = Digest::MD5->new;
    $md5->add($c);
    return $md5->hexdigest;
}

OpenQA::Test::Case->new->init_data;

# allow up to 200MB - videos mostly
$ENV{MOJO_MAX_MESSAGE_SIZE} = 207741824;

my $t = Test::Mojo->new('OpenQA::WebAPI');

# XXX: Test::Mojo loses it's app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

# INITIAL JOB LIST (from fixtures)
# 99981 cancelled  no clone
# 99963 running    no clone
# 99962 done       clone_id: 99963 (running)
# 99946 done       no clone
# 99945 done       clone_id: 99946 (also done)
# 99938 done       no clone
# 99937 done       no clone
# 99928 scheduled  no clone
# 99927 scheduled  no clone
# 99926 done       no clone

# First, let's try /jobs and ensure the initial state
my $get        = $t->get_ok('/api/v1/jobs');
my @jobs       = @{$get->tx->res->json->{jobs}};
my $jobs_count = scalar @jobs;
is($jobs_count, 12);
my %jobs = map { $_->{id} => $_ } @jobs;
is($jobs{99981}->{state},    'cancelled');
is($jobs{99963}->{state},    'running');
is($jobs{99927}->{state},    'scheduled');
is($jobs{99946}->{clone_id}, undef);
is($jobs{99963}->{clone_id}, undef);

# That means that only 9 are current and only 10 are relevant
$get = $t->get_ok('/api/v1/jobs' => form => {scope => 'current'});
is(scalar(@{$get->tx->res->json->{jobs}}), 10);
$get = $t->get_ok('/api/v1/jobs' => form => {scope => 'relevant'});
is(scalar(@{$get->tx->res->json->{jobs}}), 11);

# check limit quantity
$get = $t->get_ok('/api/v1/jobs' => form => {scope => 'current', limit => 5});
is(scalar(@{$get->tx->res->json->{jobs}}), 5);    # 9 jobs for current

# check job group
$get = $t->get_ok('/api/v1/jobs' => form => {scope => 'current', group => 'opensuse test'});
is(scalar(@{$get->tx->res->json->{jobs}}), 1);
is($get->tx->res->json->{jobs}->[0]->{id}, 99961);
$get = $t->get_ok('/api/v1/jobs' => form => {scope => 'current', group => 'foo bar'});
is(scalar(@{$get->tx->res->json->{jobs}}), 0);

# Test /jobs/restart
my $post = $t->post_ok('/api/v1/jobs/restart', form => {jobs => [99981, 99963, 99962, 99946, 99945, 99927]})->status_is(200);

$get = $t->get_ok('/api/v1/jobs');
my @new_jobs = @{$get->tx->res->json->{jobs}};
is(scalar(@new_jobs), $jobs_count + 4, '4 new jobs - for 81, 63, 46 and 61 from dependency');
my %new_jobs = map { $_->{id} => $_ } @new_jobs;
is($new_jobs{99981}->{state}, 'cancelled');
is($new_jobs{99927}->{state}, 'scheduled');
like($new_jobs{99946}->{clone_id}, qr/\d/, 'job cloned');
like($new_jobs{99963}->{clone_id}, qr/\d/, 'job cloned');
like($new_jobs{99981}->{clone_id}, qr/\d/, 'job cloned');

# The number of current jobs doesn't change
$get = $t->get_ok('/api/v1/jobs' => form => {scope => 'current'});
is(scalar(@{$get->tx->res->json->{jobs}}), 10, 'job count stay the same');

# Test /jobs/X/restart and /jobs/X
$get = $t->get_ok('/api/v1/jobs/99926')->status_is(200);
ok(!$get->tx->res->json->{job}->{clone_id}, 'job is not a clone');
$post = $t->post_ok('/api/v1/jobs/99926/restart')->status_is(200);
$get  = $t->get_ok('/api/v1/jobs/99926')->status_is(200);
like($get->tx->res->json->{job}->{clone_id}, qr/\d/, 'job cloned');

use File::Temp;
my ($fh, $filename) = File::Temp::tempfile(UNLINK => 1);
seek($fh, 20 * 1024 * 1024, 0);    # create 200MB quick
syswrite($fh, "X");
close($fh);

my $rp = "t/data/openqa/testresults/00099963-opensuse-13.1-DVD-x86_64-Build0091-kde/video.ogv";
unlink($rp);                       # make sure previous tests don't fool us
$post = $t->post_ok('/api/v1/jobs/99963/artefact' => form => {file => {file => $filename, filename => 'video.ogv'}})->status_is(200);

ok(-e $rp, 'video exist after');
is(calculate_file_md5($rp), "feeebd34e507d3a1641c774da135be77", "md5sum matches");

$rp = "t/data/openqa/testresults/00099963-opensuse-13.1-DVD-x86_64-Build0091-kde/ulogs/y2logs.tar.bz2";
$post = $t->post_ok('/api/v1/jobs/99963/artefact' => form => {file => {file => $filename, filename => 'y2logs.tar.bz2'}, ulog => 1})->status_is(200);
$post->content_is('OK');
ok(-e $rp, 'logs exist after');
is(calculate_file_md5($rp), "feeebd34e507d3a1641c774da135be77", "md5sum matches");


$rp = "t/data/openqa/factory/hdd/hdd_image.qcow2";
unlink($rp);
$post = $t->post_ok('/api/v1/jobs/99963/artefact' => form => {file => {file => $filename, filename => 'hdd_image.qcow2'}, asset => 'public'})->status_is(200);
$post->content_is('OK');
ok(-e $rp, 'asset exist after');
my $ret = $t->get_ok('/api/v1/assets/hdd/hdd_image.qcow2')->status_is(200);
is($ret->tx->res->json->{name}, 'hdd_image.qcow2');



$rp = "t/data/openqa/factory/hdd/00099963-hdd_image2.qcow2";
unlink($rp);
$post = $t->post_ok('/api/v1/jobs/99963/artefact' => form => {file => {file => $filename, filename => 'hdd_image2.qcow2'}, asset => 'private'})->status_is(200);
$post->content_is('OK');
ok(-e $rp, 'asset exist after');
$ret = $t->get_ok('/api/v1/assets/hdd/00099963-hdd_image2.qcow2')->status_is(200);
is($ret->tx->res->json->{name}, '00099963-hdd_image2.qcow2');

done_testing();
