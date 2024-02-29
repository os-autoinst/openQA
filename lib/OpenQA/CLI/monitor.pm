# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CLI::monitor;
use Mojo::Base 'OpenQA::Command', -signatures;

use OpenQA::Jobs::Constants;
use List::Util qw(all);
use Mojo::Util qw(encode getopt);

has description => 'Monitors a set of jobs';
has usage => sub { shift->extract_usage };

sub _monitor_jobs ($self, $client, $poll_interval, $job_ids, $job_results) {
    while (@$job_results < @$job_ids) {
        my $job_id = $job_ids->[@$job_results];
        my $tx = $client->build_tx(GET => $self->url_for("experimental/jobs/$job_id/status"));
        my $res = $self->retry_tx($client, $tx);
        return $res if $res != 0;
        my $job = $tx->res->json;
        my $job_state = $job->{state} // NONE;
        if (OpenQA::Jobs::Constants::meta_state($job_state) eq OpenQA::Jobs::Constants::FINAL) {
            push @$job_results, $job->{result} // NONE;
            next;
        }
        print encode('UTF-8', "Job state of job ID $job_id: $job_state, waiting …\n");
        sleep $poll_interval;
    }
}

sub _compute_return_code ($self, $job_results) {
    (all { OpenQA::Jobs::Constants::is_ok_result($_) } @$job_results) ? 0 : 2;
}

sub _monitor_and_return ($self, $client, $poll_interval, $job_ids) {
    my @job_results;
    my $monitor_res = $self->_monitor_jobs($client, $poll_interval // 10, $job_ids, \@job_results);
    return $monitor_res if $monitor_res != 0;
    return $self->_compute_return_code(\@job_results);
}

sub command ($self, @args) {
    die $self->usage unless getopt \@args, 'i|poll-interval=i' => \my $poll_interval;
    @args = $self->decode_args(@args);
    $self->_monitor_and_return($self->client($self->url_for('tests')), $poll_interval, \@args);
}

1;

=encoding utf8

=head1 SYNOPSIS

  Usage: openqa-cli monitor [OPTIONS] [JOB_IDS]

  Options:
        --apibase <path>           API base, defaults to /api/v1
        --apikey <key>             API key
        --apisecret <secret>       API secret
        --host <host>              Target host, defaults to http://localhost
    -h, --help                     Show this summary of available options
        --osd                      Set target host to http://openqa.suse.de
        --o3                       Set target host to https://openqa.opensuse.org
        --name <name>              Name of this client, used by openQA to
                                   identify different clients via User-Agent
                                   header, defaults to "openqa-cli"
    -i, --poll-interval <seconds>  Specifies the poll interval
    -p, --pretty                   Pretty print JSON content
    -q, --quiet                    Do not print error messages to STDERR
    -v, --verbose                  Print HTTP response headers

=cut
