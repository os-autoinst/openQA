#!/usr/bin/env perl
# Copyright (C) 2014-2020 SUSE LLC
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
# with this program; if not, see <http://www.gnu.org/licenses/>.

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;
use OpenQA::Client;
use Mojo::IOLoop;

use OpenQA::Utils 'locate_asset';

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 03-users.pl 04-products.pl');

my $t = Test::Mojo->new('OpenQA::WebAPI');

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

# XXX: Test::Mojo loses it's app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(
    OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

my $gru_tasks = $t->app->schema->resultset('GruTasks');

sub schedule_iso {
    my ($args, $status, $query_params) = @_;
    $status //= 200;

    my $url = Mojo::URL->new('/api/v1/isos');
    $url->query($query_params);

    $t->post_ok($url, form => $args)->status_is($status);
    return $t->tx->res;
}

my $iso = 'openSUSE-13.1-DVD-i586-Build0091-Media.iso';
my %iso = (ISO => $iso, DISTRI => 'opensuse', VERSION => '13.1', FLAVOR => 'DVD', ARCH => 'i586', BUILD => '0091');

my @tasks = $gru_tasks->search({taskname => 'download_asset'});
is(scalar @tasks, 0, 'we have no gru download tasks to start with');
$t->app->config->{global}->{download_domains} = 'localhost';
my $rsp;

# we keep checking gru task count and args over and over in this next bit,
# so let's not repeat the code over and over. If no 'expected args' are
# passed, just checks there are no download_asset tasks in the queue; if an
# array hash of 'expected args' is passed, checks there's one task in the
# queue and its args match the hash, then deletes it. $desc is appended to
# the test description so you know which one failed, if it fails.
sub check_download_asset {
    my ($desc, $expectargs) = @_;
    my $rs = $gru_tasks->search({taskname => 'download_asset'});
    if ($expectargs) {
        is($rs->count, 1, "gru task should be created: $desc");
        my $args = $rs->first->args;
        is_deeply($args, $expectargs, "download_asset task args should be as expected: $desc");
        $rs->first->delete;
    }
    else {
        is($rs->count, 0, "gru task should not be created: $desc");
    }
}

sub get_job {
    my $jobid = shift;
    $t->get_ok("/api/v1/jobs/$jobid")->status_is(200)->tx->res->json->{job};
}

sub fetch_first_job {
    my ($t, $rsp) = @_;
    get_job($rsp->json->{ids}->[0]);
}

# Similarly for checking a setting in the created jobs...takes the app, the
# response object, the setting name, the expected value and the test
# description as args.
sub check_job_setting {
    my ($t, $rsp, $setting, $expected, $desc) = @_;
    my $ret = fetch_first_job($t, $rsp);
    is($ret->{settings}->{$setting}, $expected, $desc);
}

sub job_gru {
    my $job_id = shift;
    return $t->app->schema->resultset('GruDependencies')->search({job_id => $job_id})->single->gru_task->id;
}

my $expected_job_count = 10;

# Schedule download of an existing ISO
$rsp = schedule_iso({%iso, ISO_URL => 'http://localhost/openSUSE-13.1-DVD-i586-Build0091-Media.iso'});
check_download_asset('existing ISO');

# Schedule download of an existing HDD for extraction
$rsp = schedule_iso({%iso, HDD_1_DECOMPRESS_URL => 'http://localhost/openSUSE-13.1-x86_64.hda.xz'});
check_download_asset('existing HDD');

# Schedule download of a non-existing ISO
my %params = (DISTRI => 'opensuse', VERSION => '13.1', FLAVOR => 'DVD', ARCH => 'i586');
$rsp = schedule_iso({%params, ISO_URL => 'http://localhost/nonexistent.iso'});
is($rsp->json->{count}, $expected_job_count, 'a regular ISO post creates the expected number of jobs');
check_download_asset('non-existent ISO',
    ['http://localhost/nonexistent.iso', locate_asset('iso', 'nonexistent.iso', mustexist => 0), 0]);
check_job_setting($t, $rsp, 'ISO', 'nonexistent.iso', 'parameter ISO is correctly set from ISO_URL');

# Schedule download and uncompression of a non-existing HDD
$rsp = schedule_iso({%iso, HDD_1_DECOMPRESS_URL => 'http://localhost/nonexistent.hda.xz'});
is($rsp->json->{count}, $expected_job_count, 'a regular ISO post creates the expected number of jobs');
check_download_asset('non-existent HDD (with uncompression)',
    ['http://localhost/nonexistent.hda.xz', locate_asset('hdd', 'nonexistent.hda', mustexist => 0), 1]);
check_job_setting($t, $rsp, 'HDD_1', 'nonexistent.hda', 'parameter HDD_1 correctly set from HDD_1_DECOMPRESS_URL');

# Schedule download of a non-existing ISO with a custom target name
$rsp = schedule_iso({%iso, ISO_URL => 'http://localhost/nonexistent2.iso', ISO => 'callitthis.iso'});
check_download_asset('non-existent ISO (with custom name)',
    ['http://localhost/nonexistent2.iso', locate_asset('iso', 'callitthis.iso', mustexist => 0), 0]);
check_job_setting($t, $rsp, 'ISO', 'callitthis.iso', 'parameter ISO is not overwritten when ISO_URL is set');

# Schedule download and uncompression of a non-existing kernel with a custom target name
$rsp = schedule_iso(
    {
        %params,
        KERNEL_DECOMPRESS_URL => 'http://localhost/nonexistvmlinuz',
        KERNEL                => 'callitvmlinuz'
    });
is($rsp->json->{count}, $expected_job_count, 'a regular ISO post creates the expected number of jobs');
check_download_asset('non-existent kernel (with uncompression, custom name',
    ['http://localhost/nonexistvmlinuz', locate_asset('other', 'callitvmlinuz', mustexist => 0), 1]);
check_job_setting($t, $rsp, 'KERNEL', 'callitvmlinuz',
    'parameter KERNEL is not overwritten when KERNEL_DECOMPRESS_URL is set');

# Using non-asset _URL does not create gru job and schedule jobs
$rsp = schedule_iso({%params, NO_ASSET_URL => 'http://localhost/nonexistent.iso'});
is($rsp->json->{count}, $expected_job_count, 'a regular ISO post creates the expected number of jobs');
check_download_asset('non-asset _URL');

# Using asset _URL but without filename extractable from URL create warning in log file, jobs, but no gru job
$rsp = schedule_iso({%iso, ISO_URL => 'http://localhost'});
is($rsp->json->{count}, $expected_job_count, 'a regular ISO post creates the expected number of jobs');
check_download_asset('asset _URL without valid filename');

# Using asset _URL outside of whitelist will yield 403
$rsp = schedule_iso({%iso, ISO_URL => 'http://adamshost/nonexistent.iso'}, 403);
is($rsp->body, 'Asset download requested from non-whitelisted host adamshost.');
check_download_asset('asset _URL not in whitelist');

# Using asset _DECOMPRESS_URL outside of whitelist will yield 403
$rsp = schedule_iso({%params, HDD_1_DECOMPRESS_URL => 'http://adamshost/nonexistent.hda.xz'}, 403);
is($rsp->body, 'Asset download requested from non-whitelisted host adamshost.');
check_download_asset('asset _DECOMPRESS_URL not in whitelist');

# schedule an existant ISO against a repo to verify the ISO is registered and the repo is not
$rsp = schedule_iso({%iso, REPO_1 => 'http://open.qa/any-repo'}, 200);

is_deeply(
    fetch_first_job($t, $rsp)->{assets},
    {iso => ['openSUSE-13.1-DVD-i586-Build0091-Media.iso']},
    'ISO is scheduled'
);

# Schedule an iso that triggers a gru that fails
$rsp = schedule_iso({%params, ISO_URL => 'http://localhost/failure.iso'});
is $rsp->json->{count}, $expected_job_count;
my $gru = job_gru($rsp->json->{ids}->[0]);

foreach my $j (@{$rsp->json->{ids}}) {
    my $ret = get_job($j);
    is $ret->{state}, 'scheduled';
    is $ret->{result}, 'none', 'Job has no result';
}

$gru_tasks->search({id => $gru})->single->fail;

foreach my $j (@{$rsp->json->{ids}}) {
    my $ret = get_job($j);
    is $ret->{state}, 'done';
    like $ret->{result}, qr/incomplete|skipped/, 'Job skipped/incompleted';
}

done_testing();
