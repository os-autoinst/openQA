# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CLI::schedule;
use Mojo::Base 'OpenQA::CLI::monitor', -signatures;
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
    if (my $job_count = @$job_ids) {
        my $host_url = Mojo::URL->new($self->host);
        say $job_count == 1 ? '1 job has been created:' : "$job_count jobs have been created:";
        say ' - ' . $host_url->clone->path("tests/$_") for @$job_ids;
    }
    return 0 unless my $error = $json->{error} // join("\n", map { $_->{error_message} } @{$json->{failed}});
    print STDERR colored(['red'], $error, "\n");
    return 1;
}

sub command ($self, @args) {
    die $self->usage
      unless getopt \@args,
      'param-file=s' => \my @param_file,
      'm|monitor' => \my $monitor,
      'f|follow' => \my $follow,
      'i|poll-interval=i' => \my $poll_interval,
      ;
    @args = $self->decode_args(@args);
    my $client = $self->client($self->post_url);

    my @job_ids;
    my $create_res = $self->_create_jobs($client, \@args, \@param_file, \@job_ids);
    return $create_res if $create_res != 0 || !$monitor;
    return $self->_monitor_and_return($client, $follow, $poll_interval, \@job_ids);
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
    -f, --follow                   Use the newest clone of each monitored job
        --name <name>              Name of this client, used by openQA to
                                   identify different clients via User-Agent
                                   header, defaults to "openqa-cli"
    -i, --poll-interval <seconds>  Specifies the poll interval used with --monitor
    -p, --pretty                   Pretty print JSON content
    -q, --quiet                    Do not print error messages to STDERR
    -v, --verbose                  Print HTTP response headers

=cut
