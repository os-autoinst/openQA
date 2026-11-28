#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use Mojo::Base -signatures;
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Utils;
use Mojo::File 'tempdir';
use OpenQA::Jobs::Constants;
use OpenQA::Script::CloneJob qw(create_url_handler clone_job_get_job);
use OpenQA::Test::Client 'client';
require OpenQA::Test::Database;
use OpenQA::Test::Utils qw(create_webapi stop_service);
use OpenQA::Test::TimeLimit '20';
use Test::Mojo;
use Test::Warnings ':report_warnings';
use Test::Output 'combined_like';

OpenQA::Test::Database->new->create(fixtures_glob => '01-jobs.pl');
my $t = client(Test::Mojo->new('OpenQA::WebAPI'));
my $mojoport = OpenQA::Utils::reserve_ports(['webui'])->sockport;
my $host = "localhost:$mojoport";
my @common_options = (host => $host, from => $host, apikey => 'foo', apisecret => 'bar');
my $webapi = create_webapi($mojoport, sub { });
END { stop_service $webapi; }
$t->app->config->{'scm git'}->{git_auto_update} = 'no';

my $schema = $t->app->schema;
my $products = $schema->resultset('Products');
my $testsuites = $schema->resultset('TestSuites');
my $jobs = $schema->resultset('Jobs');

my $rset = $t->app->schema->resultset('Jobs');

subtest 'multiple clones' => sub {
    $schema->txn_begin;
    my $orig = $rset->find(99946);
    my $sp = $schema->resultset('ScheduledProducts')->create({id => 23, settings => []});
    $orig->update({scheduled_product_id => $sp->id});
    my $last = $rset->find(99946);
    my $product_id = $last->related_scheduled_product_id;
    is $product_id, 23, 'Found original scheduled_product_id of clone';
    $schema->txn_rollback;
};

my $minimalx = $rset->find(99926);
my $clones = $minimalx->duplicate();
my $clone = $rset->find($clones->{$minimalx->id}->{clone});

isnt $clone->id, $minimalx->id, 'is not the same job';
is $clone->TEST, 'minimalx', 'but is the same test';
is $clone->priority, 56, 'with the same priority';
is $minimalx->state, 'done', 'original test keeps its state';
is $clone->state, 'scheduled', 'the new job is scheduled';

# Second attempt
ok $minimalx->can_be_duplicated, 'looks cloneable';
is $minimalx->duplicate, 'Job 99926 already has clone 99982', 'cannot clone again';

# Reload minimalx from the database
$minimalx->discard_changes;
is $minimalx->clone_id, $clone->id, 'relationship is set';
is $minimalx->clone->id, $clone->id, 'relationship works';
is $clone->origin->id, $minimalx->id, 'reverse relationship works';

# After reloading minimalx, it doesn't look cloneable anymore
ok !$minimalx->can_be_duplicated, 'does not look cloneable after reloading';
is $minimalx->duplicate, 'Specified job 99926 has already been cloned as 99982', 'cannot clone after reloading';

# But cloning the clone should be possible after job state change
$clone->state(OpenQA::Jobs::Constants::CANCELLED);
$clones = $clone->duplicate({prio => 35});
my $second = $rset->find($clones->{$clone->id}->{clone});
is $second->TEST, 'minimalx', 'same test again';
is $second->priority, 35, 'with adjusted priority';

subtest 'job state affects clonability' => sub {
    my $pristine_job = $jobs->find(99927);
    ok !$pristine_job->can_be_duplicated, 'scheduled job not considered cloneable';
    $pristine_job->state(ASSIGNED);
    ok !$pristine_job->can_be_duplicated, 'assigned job not considered cloneable';
    $pristine_job->state(SETUP);
    ok $pristine_job->can_be_duplicated, 'setup job considered cloneable';
};

subtest 'get job' => sub {
    my $temp_assetdir = tempdir;
    my %options = (@common_options, dir => $temp_assetdir);
    my $job_id = 4321;
    my $url_handler = create_url_handler(\%options);
    throws_ok {
        clone_job_get_job($job_id, $url_handler, \%options)
    }
    qr/failed to get job '$job_id'/, 'invalid job id results in error';

    $job_id = 99937;
    combined_like { clone_job_get_job($job_id, $url_handler, \%options) } qr/^$/, 'got job';
};

subtest 'get job with verbose output' => sub {
    # Put a .conf file in place to make sure we cover initialization of UserAgent
    my $config = tempdir;
    $config->child('client.conf')->touch;
    $ENV{OPENQA_CONFIG} = $config;

    my $temp_assetdir = tempdir;
    my %options = (@common_options, dir => $temp_assetdir, verbose => 1);
    my $url_handler;
    combined_like { $url_handler = create_url_handler(\%options); } qr/^$/,
      'Configured user agent without unexpected output';
    my $job_id = 99937;
    combined_like { clone_job_get_job($job_id, $url_handler, \%options) } qr/"id" : $job_id/, 'Job settings logged';
};

sub create_clone_chain ($first_id, $last_id, $result, $reason) {
    my @chain = map {
        $jobs->create(
            {
                id => $_,
                clone_id => $_ < $last_id ? $_ + 1 : undef,
                state => DONE,
                result => $result,
                TEST => 'foo',
                reason => $reason,
            })
    } reverse $first_id .. $last_id;
    $chain[0]->update({reason => undef});
    return \@chain;
}

subtest 'auto_clone limits' => sub {
    $schema->txn_begin;
    my $limit = 3;
    local $t->app->config->{global}{auto_clone_limit} = $limit;
    my $backend_reason = 'backend died: VNC Connection refused';
    my @jobs = @{create_clone_chain(10, 15, INCOMPLETE, $backend_reason)};
    my $last = $jobs[0];
    my ($last_incompletes, $restart, %new);

    subtest 'more than auto_clone_limit incompletes - all matching auto_clone_regex' => sub {
        $last_incompletes = $last->not_complete_ancestors($limit);
        is scalar @$last_incompletes, $limit, "not_complete_ancestors returns $limit ancestors";
        $restart = 0;
        $last->_compute_result_and_reason(\%new, 'incomplete', $backend_reason, \$restart);
        is $restart, 0, 'restart false';
        like $new{reason}, qr{Not restarting.*"auto_clone_regex".*3 times.*limit is 3}, '$reason is modified';
    };

    subtest 'more than auto_clone_limit incompletes - but less matching auto_clone_regex' => sub {
        $jobs[3]->update({reason => 'unrelated'});
        delete $last->{_not_complete_ancestors};
        $last_incompletes = $last->not_complete_ancestors($limit);
        is scalar @$last_incompletes, $limit, "not_complete_ancestors returns $limit ancestors";
        $restart = 0;
        %new = ();
        $last->_compute_result_and_reason(\%new, 'incomplete', $backend_reason, \$restart);
        is $restart, 1, 'restart true';
        like $new{reason}, qr{Auto-restarting because.*auto_clone_regex}, '$reason is modified';
    };

    subtest 'less than auto_clone_limit incompletes' => sub {
        $jobs[3]->update({result => 'failed'});
        delete $last->{_not_complete_ancestors};
        $last_incompletes = $last->not_complete_ancestors($limit);
        is scalar @$last_incompletes, 2, 'not_complete_ancestors returns a row of 2 ancestors';
        $restart = 0;
        %new = ();
        $last->_compute_result_and_reason(\%new, 'incomplete', $backend_reason, \$restart);
        is $restart, 1, 'restart true';
        like $new{reason}, qr{Auto-restarting because.*auto_clone_regex}, '$reason is modified';
    };
    $schema->txn_rollback;
};

subtest 'job exceeding the setup time is restarted by the default auto_clone_regex' => sub {
    $schema->txn_begin;
    my $reason = 'timeout: setup exceeded MAX_SETUP_TIME';
    my $job = $jobs->create({id => 99950, state => DONE, result => TIMEOUT_EXCEEDED, TEST => 'foo'});
    my %new;
    my $restart = 0;
    $job->_compute_result_and_reason(\%new, TIMEOUT_EXCEEDED, $reason, \$restart);
    is $restart, 1, 'restart is requested';
    like $new{reason}, qr{Auto-restarting because reason matches the configured "auto_clone_regex"},
      'reason is extended';
    $schema->txn_rollback;
};

subtest 'setup timeouts are not restarted beyond auto_clone_limit' => sub {
    $schema->txn_begin;
    my $limit = 3;
    local $t->app->config->{global}{auto_clone_limit} = $limit;
    my $reason = 'timeout: setup exceeded MAX_SETUP_TIME';
    my $newest = create_clone_chain(20, 23, TIMEOUT_EXCEEDED, $reason)->[0];
    is scalar @{$newest->not_complete_ancestors($limit)}, $limit, 'ancestors of the setup timeout chain are counted';
    my %new;
    my $restart = 0;
    $newest->_compute_result_and_reason(\%new, TIMEOUT_EXCEEDED, $reason, \$restart);
    is $restart, 0, 'no further restart is requested';
    like $new{reason}, qr{Not restarting.*"auto_clone_regex".*3 times.*limit is 3}, 'reason explains the limit';
    $schema->txn_rollback;
};

done_testing();
