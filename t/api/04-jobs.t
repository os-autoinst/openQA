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
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;
use OpenQA::Client;
use Mojo::IOLoop;
use Digest::MD5;
use OpenQA::IPC;
use OpenQA::WebSockets;
use OpenQA::Scheduler;
require OpenQA::Schema::Result::Jobs;

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
$t->ua(
    OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

# INITIAL JOB LIST (from fixtures)
# 99981 cancelled  no clone
# 99963 running    no clone
# 99962 done       clone_id: 99963 (running)
# 99961 running    no clone
# 99947 done       no clone
# 99946 done       no clone
# 99945 done       clone_id: 99946 (also done)
# 99944 done       clone_id: 99945 (also done)
# 99940 done       no clone
# 99939 done       no clone
# 99938 done       no clone
# 99937 done       no clone
# 99936 done       no clone
# 99928 scheduled  no clone
# 99927 scheduled  no clone
# 99926 done       no clone

# First, let's try /jobs and ensure the initial state
my $get        = $t->get_ok('/api/v1/jobs');
my @jobs       = @{$get->tx->res->json->{jobs}};
my $jobs_count = scalar @jobs;
is($jobs_count, 16);
my %jobs = map { $_->{id} => $_ } @jobs;
is($jobs{99981}->{state},    'cancelled');
is($jobs{99963}->{state},    'running');
is($jobs{99927}->{state},    'scheduled');
is($jobs{99946}->{clone_id}, undef);
is($jobs{99963}->{clone_id}, undef);

# That means that only 9 are current and only 10 are relevant
$get = $t->get_ok('/api/v1/jobs' => form => {scope => 'current'});
is(scalar(@{$get->tx->res->json->{jobs}}), 13);
$get = $t->get_ok('/api/v1/jobs' => form => {scope => 'relevant'});
is(scalar(@{$get->tx->res->json->{jobs}}), 14);

# check limit quantity
$get = $t->get_ok('/api/v1/jobs' => form => {scope => 'current', limit => 5});
is(scalar(@{$get->tx->res->json->{jobs}}), 5);    # 9 jobs for current

# check job group
$get = $t->get_ok('/api/v1/jobs' => form => {scope => 'current', group => 'opensuse test'});
is(scalar(@{$get->tx->res->json->{jobs}}), 1);
is($get->tx->res->json->{jobs}->[0]->{id}, 99961);
$get = $t->get_ok('/api/v1/jobs' => form => {scope => 'current', group => 'foo bar'});
is(scalar(@{$get->tx->res->json->{jobs}}), 0);

# Test restricting list

# query for existing jobs by iso
$get = $t->get_ok('/api/v1/jobs?iso=openSUSE-13.1-DVD-i586-Build0091-Media.iso');
is(scalar(@{$get->tx->res->json->{jobs}}), 6);

# query for existing jobs by build
$get = $t->get_ok('/api/v1/jobs?build=0091');
is(scalar(@{$get->tx->res->json->{jobs}}), 10);

# query for existing jobs by hdd_1
$get = $t->get_ok('/api/v1/jobs?hdd_1=openSUSE-13.1-x86_64.hda');
is(scalar(@{$get->tx->res->json->{jobs}}), 3);

# query for some combinations with test
$get = $t->get_ok('/api/v1/jobs?test=kde');
is(scalar(@{$get->tx->res->json->{jobs}}), 6);
$get = $t->get_ok('/api/v1/jobs?test=kde&result=passed');
is(scalar(@{$get->tx->res->json->{jobs}}), 1);
$get = $t->get_ok('/api/v1/jobs?test=kde&result=softfailed');
is(scalar(@{$get->tx->res->json->{jobs}}), 2);
$get = $t->get_ok('/api/v1/jobs?test=kde&result=softfailed&machine=64bit');
is(scalar(@{$get->tx->res->json->{jobs}}), 1);
$get = $t->get_ok('/api/v1/jobs?test=kde&result=passed&machine=64bit');
is(scalar(@{$get->tx->res->json->{jobs}}), 0);

# test limiting options
$get = $t->get_ok('/api/v1/jobs?limit=5');
is(scalar(@{$get->tx->res->json->{jobs}}), 5);
$get = $t->get_ok('/api/v1/jobs?limit=1');
is(scalar(@{$get->tx->res->json->{jobs}}), 1);
is($get->tx->res->json->{jobs}->[0]->{id}, 99981);
$get = $t->get_ok('/api/v1/jobs?limit=1&page=2');
is(scalar(@{$get->tx->res->json->{jobs}}), 1);
is($get->tx->res->json->{jobs}->[0]->{id}, 99963);
$get = $t->get_ok('/api/v1/jobs?before=99928');
is(scalar(@{$get->tx->res->json->{jobs}}), 2);
$get = $t->get_ok('/api/v1/jobs?after=99945');
is(scalar(@{$get->tx->res->json->{jobs}}), 6);

# test multiple arg forms
$get = $t->get_ok('/api/v1/jobs?ids=99981,99963,99926');
is(scalar(@{$get->tx->res->json->{jobs}}), 3);
$get = $t->get_ok('/api/v1/jobs?ids=99981&ids=99963&ids=99926');
is(scalar(@{$get->tx->res->json->{jobs}}), 3);

# Test /jobs/restart
my $post = $t->post_ok('/api/v1/jobs/restart', form => {jobs => [99981, 99963, 99962, 99946, 99945, 99927, 99939]})
  ->status_is(200);

$get = $t->get_ok('/api/v1/jobs');
my @new_jobs = @{$get->tx->res->json->{jobs}};
is(scalar(@new_jobs), $jobs_count + 5, '5 new jobs - for 81, 63, 46, 39 and 61 from dependency');
my %new_jobs = map { $_->{id} => $_ } @new_jobs;
is($new_jobs{99981}->{state}, 'cancelled');
is($new_jobs{99927}->{state}, 'scheduled');
like($new_jobs{99939}->{clone_id}, qr/\d/, 'job cloned');
like($new_jobs{99946}->{clone_id}, qr/\d/, 'job cloned');
like($new_jobs{99963}->{clone_id}, qr/\d/, 'job cloned');
like($new_jobs{99981}->{clone_id}, qr/\d/, 'job cloned');
my $cloned = $new_jobs{$new_jobs{99939}->{clone_id}};

# The number of current jobs doesn't change
$get = $t->get_ok('/api/v1/jobs' => form => {scope => 'current'});
is(scalar(@{$get->tx->res->json->{jobs}}), 13, 'job count stay the same');

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

my $rp = "t/data/openqa/testresults/00099/00099963-opensuse-13.1-DVD-x86_64-Build0091-kde/video.ogv";
unlink($rp);                       # make sure previous tests don't fool us
$post = $t->post_ok('/api/v1/jobs/99963/artefact' => form => {file => {file => $filename, filename => 'video.ogv'}})
  ->status_is(200);

ok(-e $rp, 'video exist after');
is(calculate_file_md5($rp), "feeebd34e507d3a1641c774da135be77", "md5sum matches");

$rp = "t/data/openqa/testresults/00099/00099963-opensuse-13.1-DVD-x86_64-Build0091-kde/ulogs/y2logs.tar.bz2";
$post
  = $t->post_ok(
    '/api/v1/jobs/99963/artefact' => form => {file => {file => $filename, filename => 'y2logs.tar.bz2'}, ulog => 1})
  ->status_is(200);
$post->content_is('OK');
ok(-e $rp, 'logs exist after');
is(calculate_file_md5($rp), "feeebd34e507d3a1641c774da135be77", "md5sum matches");


$rp = "t/data/openqa/factory/hdd/hdd_image.qcow2";
unlink($rp);
$post = $t->post_ok('/api/v1/jobs/99963/artefact' => form =>
      {file => {file => $filename, filename => 'hdd_image.qcow2'}, asset => 'public'})->status_is(200);
my $temp = $post->tx->res->json->{temporary};
like($temp, qr,t/data/openqa/factory/hdd/hdd_image\.qcow2\.TEMP.*,);
ok(-e $temp, "temporary exists");
ok(!-e $rp,  "asset doesn't exist after");
$t->post_ok('/api/v1/jobs/99963/ack_temporary' => form => {temporary => $temp});
ok(!-e $temp, "temporary is gone");
ok(-e $rp,    "asset exist after ACK");
my $ret = $t->get_ok('/api/v1/assets/hdd/hdd_image.qcow2')->status_is(200);
is($ret->tx->res->json->{name}, 'hdd_image.qcow2');

$rp = "t/data/openqa/factory/hdd/00099963-hdd_image2.qcow2";
unlink($rp);
$post = $t->post_ok('/api/v1/jobs/99963/artefact' => form =>
      {file => {file => $filename, filename => 'hdd_image2.qcow2'}, asset => 'private'})->status_is(200);
$temp = $post->tx->res->json->{temporary};
like($temp, qr,t/data/openqa/factory/hdd/00099963-hdd_image2\.qcow2\.TEMP.*,);
$t->post_ok('/api/v1/jobs/99963/ack_temporary' => form => {temporary => $temp});
ok(-e $rp, 'asset exist after');
$ret = $t->get_ok('/api/v1/assets/hdd/00099963-hdd_image2.qcow2')->status_is(200);
is($ret->tx->res->json->{name}, '00099963-hdd_image2.qcow2');

# /api/v1/jobs supports filtering by state, result
my $query = Mojo::URL->new('/api/v1/jobs');
for my $state (OpenQA::Schema::Result::Jobs->STATES) {
    $query->query(state => $state);
    $get = $t->get_ok($query->path_query)->status_is(200);
    my $res = $get->tx->res->json;
    for my $job (@{$res->{jobs}}) {
        is($job->{state}, $state);
    }
}

for my $result (OpenQA::Schema::Result::Jobs->RESULTS) {
    $query->query(result => $result);
    $get = $t->get_ok($query->path_query)->status_is(200);
    my $res = $get->tx->res->json;
    for my $job (@{$res->{jobs}}) {
        is($job->{result}, $result);
    }
}

for my $result ('failed,none', 'passed,none', 'failed,passed') {
    $query->query(result => $result);
    $get = $t->get_ok($query->path_query)->status_is(200);
    my $res  = $get->tx->res->json;
    my $cond = $result =~ s/,/|/r;
    for my $job (@{$res->{jobs}}) {
        like($job->{result}, qr/$cond/);
    }
}

$query->query(result => 'nonexistent_result');
$get = $t->get_ok($query->path_query)->status_is(200);
my $res = $get->tx->res->json;
ok(!@{$res->{jobs}}, 'no result for nonexising result');

$query->query(state => 'nonexistent_state');
$get = $t->get_ok($query->path_query)->status_is(200);
$res = $get->tx->res->json;
ok(!@{$res->{jobs}}, 'no result for nonexising state');

# Test /jobs/cancel
# TODO: cancelling jobs via API in tests doesn't work for some reason
#
# $post = $t->post_ok('/api/v1/jobs/cancel?BUILD=0091')->status_is(200);
#
# $get = $t->get_ok('/api/v1/jobs');
# @new_jobs = @{$get->tx->res->json->{jobs}};
#
# foreach my $job (@new_jobs) {
#     if ($job->{settings}->{BUILD} eq '0091') {
#         is($job->{state}, 'cancelled', "job $job->{id} was cancelled");
#     }
# }
#
# is($cloned->{state}, 'scheduled');

# delete the job with a registered job module
my $delete = $t->delete_ok('/api/v1/jobs/99937')->status_is(200);
$t->get_ok('/api/v1/jobs/99937')->status_is(404);

$get = $t->get_ok('/group_overview/1001.json')->status_is(200);
$get = $get->tx->res->json;
is_deeply({id => 1001, name => 'opensuse'}, $get->{group});
my $b48 = $get->{result}->{'0048'};
delete $b48->{oldest};
is_deeply(
    {
        reviewed            => '',
        softfailed          => 1,
        failed              => 1,
        labeled             => 0,
        reviewed_all_passed => '',
        total               => 3,
        passed              => 0,
        skipped             => 0,
        distri              => 'opensuse',
        unfinished          => 1,
        version             => 'Factory',
        escaped_id          => '0048',
    },
    $b48,
    'Build 0048 exported'
);

$get = $t->get_ok('/index.json')->status_is(200);
$get = $get->tx->res->json;
is(@{$get->{results}}, 2);
my $g1 = (shift @{$get->{results}});
is($g1->{group}->{name}, 'opensuse', 'First group is opensuse');
my $b1 = $g1->{result}->{'0092'};
delete $b1->{oldest};
is_deeply(
    $b1,
    {
        passed              => 1,
        version             => '13.1',
        distri              => 'opensuse',
        labeled             => 0,
        total               => 1,
        failed              => 0,
        unfinished          => 0,
        skipped             => 0,
        reviewed            => '',
        softfailed          => 0,
        reviewed_all_passed => 1,
        escaped_id          => '0092',
    },
    'Build 92 of opensuse'
);

done_testing();
