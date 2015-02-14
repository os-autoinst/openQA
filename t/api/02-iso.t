# Copyright (C) 2014 SUSE Linux Products GmbH
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

BEGIN {
    unshift @INC, 'lib';
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use OpenQA::Test::Case;
use OpenQA::Client;
use Mojo::IOLoop;
use Data::Dump;

OpenQA::Test::Case->new->init_data;

my $t = Test::Mojo->new('OpenQA');

# XXX: Test::Mojo loses it's app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

sub lj {
    return unless $ENV{HARNESS_IS_VERBOSE};
    my $ret = $t->get_ok('/api/v1/jobs')->status_is(200);
    my @jobs = @{$ret->tx->res->json->{jobs}};
    for my $j (@jobs) {
        printf "%d %-10s %s\n", $j->{id}, $j->{state}, $j->{name};
    }
}

my $ret;

my $iso = 'openSUSE-13.1-DVD-i586-Build0091-Media.iso';

$ret = $t->get_ok('/api/v1/jobs/99927')->status_is(200);
is($ret->tx->res->json->{job}->{state}, 'scheduled', 'job 99927 is scheduled');
$ret = $t->get_ok('/api/v1/jobs/99928')->status_is(200);
is($ret->tx->res->json->{job}->{state}, 'scheduled', 'job 99928 is scheduled');
$ret = $t->get_ok('/api/v1/jobs/99963')->status_is(200);
is($ret->tx->res->json->{job}->{state}, 'running', 'job 99963 is running');

$ret = $t->get_ok('/api/v1/jobs/99981')->status_is(200);
is($ret->tx->res->json->{job}->{state}, 'cancelled', 'job 99981 is cancelled');

$ret = $t->post_ok('/api/v1/jobs/99981/restart')->status_is(200);

lj;

# schedule the iso, this should not actually be possible. Only isos
# with different name should result in new tests...
$ret = $t->post_ok('/api/v1/isos', form => { ISO => $iso, DISTRI => 'opensuse', VERSION => '13.1', FLAVOR => 'DVD', ARCH => 'i586', BUILD => '0091' })->status_is(200);

is($ret->tx->res->json->{count}, 2, "two new jobs created");
my @newids = @{$ret->tx->res->json->{ids}};
my $newid = $newids[0];

lj;

# check that the old tests are cancelled
$ret = $t->get_ok('/api/v1/jobs/99927')->status_is(200);
is($ret->tx->res->json->{job}->{state}, 'cancelled', 'job 99927 is cancelled');

$ret = $t->get_ok('/api/v1/jobs/99928')->status_is(200);
is($ret->tx->res->json->{job}->{state}, 'cancelled', 'job 99928 is cancelled');
$ret = $t->get_ok('/api/v1/jobs/99963')->status_is(200);
is($ret->tx->res->json->{job}->{state}, 'running', 'job 99963 is running');

# make sure unrelated jobs are not cancelled
$ret = $t->get_ok('/api/v1/jobs/99981')->status_is(200);
is($ret->tx->res->json->{job}->{state}, 'scheduled', "job 99981 is still scheduled");

# ... and we have a new test
$ret = $t->get_ok("/api/v1/jobs/$newid")->status_is(200);
is($ret->tx->res->json->{job}->{state}, 'scheduled', "new job $newid is scheduled");

# cancel the iso
$ret = $t->post_ok("/api/v1/isos/$iso/cancel")->status_is(200);

$ret = $t->get_ok("/api/v1/jobs/$newid")->status_is(200);
is($ret->tx->res->json->{job}->{state}, 'cancelled', "job $newid is cancelled");

# make sure we can't post invalid parameters
$ret = $t->post_ok('/api/v1/isos', form => { iso => $iso, tests => "kde/usb" })->status_is(400);

TODO: {
    local $TODO = 'iso delete doesnt seem to work';

    # delete the iso
    $ret = $t->delete_ok("/api/v1/isos/$iso")->status_is(200);
    # now the jobs should be gone
    $ret = $t->get_ok('/api/v1/jobs/99982')->status_is(404);
}

done_testing();
