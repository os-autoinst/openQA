# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CLI::monitor;
use Mojo::Base 'OpenQA::Command', -signatures;

use OpenQA::Jobs::Constants;
use List::Util qw(all);
use Mojo::Util qw(encode);
use Term::ANSIColor qw(colored);

has description => 'Monitors a set of jobs';
has usage => sub { OpenQA::CLI->_help('monitor') };

sub _error_from_json ($self, $json) {
    return $json->{error} // join "\n", map { $_->{error_message} } @{$json->{failed}};
}

sub _populate_job_ids ($self, $results, $job_ids) {
    return 'No results present' unless ref $results eq 'HASH';
    my $ids = $results->{successful_job_ids};
    return 'No successful job IDs present' unless ref $ids eq 'ARRAY';
    push @$job_ids, @$ids;
    return 0;
}

sub _wait_for_jobs ($self, $client, $poll_interval, $scheduled_product_id, $job_ids) {
    return undef unless $scheduled_product_id;
    my %pending_statuses = (added => 1, scheduling => 1);
    my $status = 'added';
    while (exists $pending_statuses{$status}) {
        my $tx = $client->build_tx(GET => $self->url_for("isos/$scheduled_product_id"));
        my $res = $self->retry_tx($client, $tx);
        return $res if $res != 0;
        my $json = $tx->res->json;
        $status = $json->{status} // '?';
        my $results = $json->{results};
        my $error = $self->_error_from_json($results // $json);
        return $error if $error;
        return $self->_populate_job_ids($results, $job_ids) if $status eq 'scheduled';
        sleep $poll_interval;
    }
    return "Scheduled product $scheduled_product_id ended up $status";
}

sub _monitor_jobs ($self, $client, $follow, $poll_interval, $job_ids, $job_results) {
    my $start = time;
    while (@$job_results < @$job_ids) {
        my $job_id = $job_ids->[@$job_results];
        my $url = $self->url_for("experimental/jobs/$job_id/status");
        $url->query(follow => 1) if $follow;
        my $tx = $client->build_tx(GET => $url);
        my $res = $self->retry_tx($client, $tx);
        return $res if $res != 0;
        my $job = $tx->res->json;
        my $job_state = $job->{state} // NONE;
        if (OpenQA::Jobs::Constants::meta_state($job_state) eq OpenQA::Jobs::Constants::FINAL) {
            push @$job_results, $job->{result} // NONE;
            next;
        }
        my $waited = time - $start;
        print encode('UTF-8',
            "Job state of job ID $job_id: $job_state, waiting … (delay: $poll_interval; waited ${waited}s)\n");
        sleep $poll_interval;
    }
}

sub _compute_return_code ($self, $job_results) {
    (all { OpenQA::Jobs::Constants::is_ok_result($_) } @$job_results) ? 0 : 2;
}

sub _monitor_and_return ($self, $client, $follow, $poll_interval, $job_ids) {
    my @job_results;
    my $monitor_res = $self->_monitor_jobs($client, $follow, $poll_interval // 10, $job_ids, \@job_results);
    return $monitor_res if $monitor_res != 0;
    return $self->_compute_return_code(\@job_results);
}

sub command ($self, @args) {
    die $self->usage unless OpenQA::CLI::get_opt(monitor => \@args, [], \my %options);

    @args = $self->decode_args(@args);
    my $client = $self->client($self->url_for('tests'));
    my $poll_interval = $options{'poll-interval'} // 10;
    my @job_ids = @args;

    if (my $sp_id = $options{'scheduled-product-id'}) {
        my $error = $self->_wait_for_jobs($client, $poll_interval, $sp_id, \@job_ids);
        if ($error) {
            print STDERR colored(['red'], $error, "\n");
            return 1;
        }
    }

    die $self->usage unless @job_ids;
    $self->_monitor_and_return($client, $options{follow}, $poll_interval, \@job_ids);
}

1;
