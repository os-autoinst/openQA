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
  unshift @INC, 'lib', 'lib/OpenQA/modules';
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use OpenQA::Test::Case;
use OpenQA::API::V1::Client;
use Mojo::IOLoop;
use Data::Dump;

OpenQA::Test::Case->new->init_data;

my $t = Test::Mojo->new('OpenQA');

# XXX: Test::Mojo loses it's app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(OpenQA::API::V1::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')->ioloop(Mojo::IOLoop->singleton));
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
my $get = $t->get_ok('/api/v1/jobs');
my @jobs = @{$get->tx->res->json->{jobs}};
my $jobs_count = scalar @jobs;
is $jobs_count, 10;
my %jobs = map { $_->{id} => $_ } @jobs;
is $jobs{99981}->{state}, 'cancelled';
is $jobs{99963}->{state}, 'running';
is $jobs{99927}->{state}, 'scheduled';
is $jobs{99946}->{clone_id}, undef;
is $jobs{99963}->{clone_id}, undef;

# Test /jobs/restart
my $post = $t->post_ok('/api/v1/jobs/restart', form => {jobs => [99981, 99963, 99962, 99946, 99945, 99927] })->status_is(200);

$get = $t->get_ok('/api/v1/jobs');
my @new_jobs = @{$get->tx->res->json->{jobs}};
is scalar(@new_jobs), $jobs_count + 2;
my %new_jobs = map { $_->{id} => $_ } @new_jobs;
is $new_jobs{99981}->{state}, 'scheduled';
is $new_jobs{99927}->{state}, 'scheduled';
isnt $new_jobs{99946}->{clone_id}, undef;
isnt $new_jobs{99963}->{clone_id}, undef;

# Test /jobs/X/restart and /jobs/X
$get = $t->get_ok('/api/v1/jobs/99926')->status_is(200);
is $get->tx->res->json->{job}->{clone_id}, undef;
$post = $t->post_ok('/api/v1/jobs/99926/restart')->status_is(200);
$get = $t->get_ok('/api/v1/jobs/99926')->status_is(200);
isnt $get->tx->res->json->{job}->{clone_id}, undef;

done_testing();
