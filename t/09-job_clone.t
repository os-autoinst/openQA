#!/usr/bin/env perl
# Copyright 2014-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Utils;
use Mojo::File 'tempdir';
use OpenQA::Jobs::Constants;
use OpenQA::Script::CloneJob;
use OpenQA::Test::Client 'client';
use OpenQA::Test::Database;
use OpenQA::Test::Utils qw(create_webapi stop_service);
use OpenQA::Test::TimeLimit '20';
use Test::Mojo;
use Test::Warnings ':report_warnings';
use Test::Output 'combined_like';

OpenQA::Test::Database->new->create(fixtures_glob => '01-jobs.pl');
my $t = client(Test::Mojo->new('OpenQA::WebAPI'));
my $mojoport = Mojo::IOLoop::Server->generate_port;
my $host = "localhost:$mojoport";
my @common_options = (host => $host, from => $host, apikey => 'foo', apisecret => 'bar');
my $webapi = create_webapi($mojoport, sub { });
END { stop_service $webapi; }

my $schema = $t->app->schema;
my $products = $schema->resultset("Products");
my $testsuites = $schema->resultset("TestSuites");
my $jobs = $schema->resultset("Jobs");

my $rset = $t->app->schema->resultset("Jobs");
my $minimalx = $rset->find(99926);
my $clones = $minimalx->duplicate();
my $clone = $rset->find($clones->{$minimalx->id}->{clone});

isnt($clone->id, $minimalx->id, "is not the same job");
is($clone->TEST, "minimalx", "but is the same test");
is($clone->priority, 56, "with the same priority");
is($minimalx->state, "done", "original test keeps its state");
is($clone->state, "scheduled", "the new job is scheduled");

# Second attempt
ok($minimalx->can_be_duplicated, 'looks cloneable');
is($minimalx->duplicate, 'Job 99926 already has clone 99982', 'cannot clone again');

# Reload minimalx from the database
$minimalx->discard_changes;
is($minimalx->clone_id, $clone->id, "relationship is set");
is($minimalx->clone->id, $clone->id, "relationship works");
is($clone->origin->id, $minimalx->id, "reverse relationship works");

# After reloading minimalx, it doesn't look cloneable anymore
ok(!$minimalx->can_be_duplicated, 'does not look cloneable after reloading');
is($minimalx->duplicate, 'Specified job 99926 has already been cloned as 99982', 'cannot clone after reloading');

# But cloning the clone should be possible after job state change
$clone->state(OpenQA::Jobs::Constants::CANCELLED);
$clones = $clone->duplicate({prio => 35});
my $second = $rset->find($clones->{$clone->id}->{clone});
is($second->TEST, "minimalx", "same test again");
is($second->priority, 35, "with adjusted priority");

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
    my %options = (@common_options, dir => $temp_assetdir);
    my $job_id = 4321;
    my ($ua, $local, $local_url, $remote, $remote_url) = create_url_handler(\%options);
    throws_ok {
        clone_job_get_job($job_id, $remote, $remote_url, \%options)
    }
    qr/failed to get job '$job_id'/, 'invalid job id results in error';

    $job_id = 99937;
    combined_like { clone_job_get_job($job_id, $remote, $remote_url, \%options) } qr/^$/, 'got job';
};

subtest 'get job with verbose output' => sub {
    # Put a .conf file in place to make sure we cover initialization of UserAgent
    my $config = tempdir;
    $config->child("client.conf")->touch;
    $ENV{OPENQA_CONFIG} = $config;

    my $temp_assetdir = tempdir;
    my %options = (@common_options, dir => $temp_assetdir, verbose => 1);
    my ($ua, $local, $local_url, $remote, $remote_url);
    combined_like { ($ua, $local, $local_url, $remote, $remote_url) = create_url_handler(\%options); } qr/^$/,
      'Configured user agent without unexpected output';
    my $job_id = 99937;
    combined_like { clone_job_get_job($job_id, $remote, $remote_url, \%options) } qr/"id" : $job_id/,
      'Job settings logged';
};

done_testing();
