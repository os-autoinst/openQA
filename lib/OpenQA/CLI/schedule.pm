# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CLI::schedule;
use OpenQA::Jobs::Constants;
use Mojo::Base 'OpenQA::Command', -signatures;
use Mojo::Util qw(encode getopt);
use Term::ANSIColor qw(colored);

has description => 'Schedules a set of jobs (via "isos post" creating a schedule product)';
has usage => sub { shift->extract_usage };
has post_url => sub { shift->url_for('isos') };

sub _create_jobs ($self, $client, $args, $param_file, $job_ids) {
    my $params = $self->parse_params($args, $param_file);
    my $tx = $client->build_tx(POST => $self->post_url, {}, form => $params);
    my $res = $self->retry_tx($client, $tx);
    return $res if $res != 0;
    my $json = $tx->res->json;
    push @$job_ids, $json->{id} if defined $json->{id} && ref $json->{id} eq '';
    push @$job_ids, @{$json->{ids}} if ref $json->{ids} eq 'ARRAY';
    return 0 unless my $error = $json->{error};
    print STDERR colored(['red'], $error, "\n");
    return 1;
}

sub _monitor_jobs ($self, $client, $poll_interval, $job_ids, $job_results) {
    while (@$job_results < @$job_ids) {
        my $job_id = $job_ids->[@$job_results];
        my $tx = $client->build_tx(GET => $self->url_for("experimental/jobs/$job_id/status"), {});
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
    for my $job_result (@$job_results) {
        return 2 unless OpenQA::Jobs::Constants::is_ok_result($job_result);
    }
    return 0;
}

sub command ($self, @args) {
    die $self->usage
      unless getopt \@args,
      'param-file=s' => \my @param_file,
      'm|monitor' => \my $monitor,
      'i|poll-interval=i' => \my $poll_interval,
      ;
    @args = $self->decode_args(@args);
    my $client = $self->client($self->post_url);

    my @job_ids;
    my $create_res = $self->_create_jobs($client, \@args, \@param_file, \@job_ids);
    return $create_res if $create_res != 0 || !$monitor;

    my @job_results;
    my $monitor_res = $self->_monitor_jobs($client, $poll_interval // 10, \@job_ids, \@job_results);
    return $monitor_res if $monitor_res != 0;
    return $self->_compute_return_code(\@job_results);
}

1;

=encoding utf8

=head1 SYNOPSIS

  Usage: openqa-cli schedule [OPTIONS] DISTRI=… VERSION=… FLAVOR=… ARCH=… [ISO=… …]

  Options:
        --apibase <path>           API base, defaults to /api/v1
        --apikey <key>             API key
        --apisecret <secret>       API secret
        --host <host>              Target host, defaults to http://localhost
    -h, --help                     Show this summary of available options
        --osd                      Set target host to http://openqa.suse.de
        --o3                       Set target host to https://openqa.opensuse.org
        --param-file <param=file>  Load content of params from files instead of
                                   from command line arguments. Multiple params
                                   may be specified by adding the option
                                   multiple times
    -m, --monitor                  Wait until all jobs are done/cancelled and return
                                   non-zero exit code if at least on job has not
                                   passed/softfailed
    -i, --poll-interval            Specifies the poll interval used with --monitor
    -p, --pretty                   Pretty print JSON content
    -q, --quiet                    Do not print error messages to STDERR
    -v, --verbose                  Print HTTP response headers

=cut
