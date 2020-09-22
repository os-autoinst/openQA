#!/usr/bin/env perl
# Copyright (C) 2014-2020 SUSE LLC
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
use lib "$FindBin::Bin/lib";
use OpenQA::Utils;
use Mojo::File 'tempdir';
use OpenQA::Jobs::Constants;
use OpenQA::Script::CloneJob;
use OpenQA::Test::Client 'client';
use OpenQA::Test::Database;
use OpenQA::Test::Utils qw(create_webapi stop_service);
use OpenQA::Test::TimeLimit '50';
use Test::Mojo;
use Test::Warnings ':report_warnings';

OpenQA::Test::Database->new->create(fixtures_glob => '01-jobs.pl');
my $t        = client(Test::Mojo->new('OpenQA::WebAPI'));
my $mojoport = Mojo::IOLoop::Server->generate_port;
my $host     = "localhost:$mojoport";
my $webapi   = create_webapi($mojoport, sub { });
END { stop_service $webapi; }

my $schema     = $t->app->schema;
my $products   = $schema->resultset("Products");
my $testsuites = $schema->resultset("TestSuites");
my $jobs       = $schema->resultset("Jobs");

my $rset     = $t->app->schema->resultset("Jobs");
my $minimalx = $rset->find(99926);
my $clones   = $minimalx->duplicate();
my $clone    = $rset->find($clones->{$minimalx->id}->{clone});

isnt($clone->id, $minimalx->id, "is not the same job");
is($clone->TEST,     "minimalx",  "but is the same test");
is($clone->priority, 56,          "with the same priority");
is($minimalx->state, "done",      "original test keeps its state");
is($clone->state,    "scheduled", "the new job is scheduled");

# Second attempt
ok($minimalx->can_be_duplicated, 'looks cloneable');
is($minimalx->duplicate, 'Job 99926 has already been cloned as 99982', 'cannot clone again');

# Reload minimalx from the database
$minimalx->discard_changes;
is($minimalx->clone_id,  $clone->id,    "relationship is set");
is($minimalx->clone->id, $clone->id,    "relationship works");
is($clone->origin->id,   $minimalx->id, "reverse relationship works");

# After reloading minimalx, it doesn't look cloneable anymore
ok(!$minimalx->can_be_duplicated, 'does not look cloneable after reloading');
is($minimalx->duplicate, 'Job 99926 has already been cloned as 99982', 'cannot clone after reloading');

# But cloning the clone should be possible after job state change
$clone->state(OpenQA::Jobs::Constants::CANCELLED);
$clones = $clone->duplicate({prio => 35});
my $second = $rset->find($clones->{$clone->id}->{clone});
is($second->TEST,     "minimalx", "same test again");
is($second->priority, 35,         "with adjusted priority");

subtest 'job state affects clonability' => sub {
    my $pristine_job = $jobs->find(99927);
    ok(!$pristine_job->can_be_duplicated, 'scheduled job not considered cloneable');
    $pristine_job->state(ASSIGNED);
    ok(!$pristine_job->can_be_duplicated, 'assigned job not considered cloneable');
    $pristine_job->state(SETUP);
    ok($pristine_job->can_be_duplicated, 'setup job considered cloneable');
};

subtest 'get job' => sub {
    my $temp_assetdir = tempdir;
    my %options       = (dir => $temp_assetdir, host => $host, from => $host);
    my $job_id        = 4321;
    my ($ua, $local, $local_url, $remote, $remote_url) = create_url_handler(\%options);
    throws_ok {
        clone_job_get_job($job_id, $remote, $remote_url, \%options)
    }
    qr/failed to get job '$job_id'/, 'invalid job id results in error';

    $job_id = 99937;
    lives_ok { clone_job_get_job($job_id, $remote, $remote_url, \%options) } 'got job';
};

done_testing();
