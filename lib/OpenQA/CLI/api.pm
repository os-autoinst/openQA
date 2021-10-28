# Copyright 2020-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CLI::api;
use Mojo::Base 'OpenQA::Command';

use Mojo::File 'path';
use Mojo::JSON qw(decode_json);
use Mojo::Util qw(getopt);

has description => 'Issue an arbitrary request to the API';
has usage => sub { shift->extract_usage };

sub command {
    my ($self, @args) = @_;

    my $data = $self->data_from_stdin;

    die $self->usage
      unless getopt \@args,
      'a|header=s' => \my @headers,
      'D|data-file=s' => \my $data_file,
      'd|data=s' => \$data,
      'f|form' => \my $form,
      'j|json' => \my $json,
      'param-file=s' => \my @param_file,
      'p|pretty' => \my $pretty,
      'q|quiet' => \my $quiet,
      'r|retries=i' => \my $retries,
      'X|method=s' => \(my $method = 'GET'),
      'v|verbose' => \my $verbose;

    @args = $self->decode_args(@args);
    die $self->usage unless my $path = shift @args;

    $data = path($data_file)->slurp if $data_file;
    my @data = ($data);
    my $params = $form ? decode_json($data) : $self->parse_params(\@args, \@param_file);
    @data = (form => $params) if keys %$params;

    my $headers = $self->parse_headers(@headers);
    $headers->{Accept} //= 'application/json';
    $headers->{'Content-Type'} = 'application/json' if $json;

    my $url = $self->url_for($path);
    my $client = $self->client($url);
    my $tx = $client->build_tx($method, $url, $headers, @data);
    my $ret;
    $retries //= $ENV{OPENQA_CLI_RETRIES} // 0;
    do {
        $tx = $client->start($tx);
        my $res_code = $tx->res->code;
        return $self->handle_result($tx, {pretty => $pretty, quiet => $quiet, verbose => $verbose})
          unless $res_code =~ /50[23]/ && $retries > 0;
        print "Request failed, hit error $res_code, retrying up to $retries more times after waiting ...\n";
        sleep($ENV{OPENQA_CLI_RETRY_SLEEP_TIME_S} // 3);
        $retries--;
    } while ($retries > 0);
    return 1;
}

1;

=encoding utf8

=head1 SYNOPSIS

  Usage: openqa-cli api [OPTIONS] PATH [PARAMS]

    # Show details for job from localhost
    openqa-cli api jobs/4160811

    # Show details for job from arbitrary host
    openqa-cli api --host http://openqa.example.com jobs/408

    # Show details for job from OSD (prettified JSON)
    openqa-cli api --osd --pretty jobs/4160811

    # List all jobs (CAUTION: this might time out for a large instance)
    openqa-cli api --host openqa.example.com jobs

    # List all jobs matching the search criteria
    openqa-cli api --osd jobs groupid=135 distri=caasp version=3.0 latest=1

    # List the latest jobs matching the search criteria
    openqa-cli api --osd jobs/overview groupid=135 distri=caasp version=3.0

    # Restart a job
    openqa-cli api -X POST jobs/16/restart

    # Delete job (CAUTION: destructive operation)
    openqa-cli api --host openqa.example.com -X DELETE jobs/1

    # Trigger a single job
    openqa-cli api -X POST jobs ISO=foo.iso DISTRI=my-distri \
      FLAVOR=my-flavor VERSION=42 BUILD=42 TEST=my-test

    # Trigger jobs on ISO "foo.iso"
    openqa-cli api --o3 -X POST isos ISO=foo.iso DISTRI=my-distri \
      FLAVOR=my-flavor ARCH=my-arch VERSION=42 BUILD=1234

    # Change group id for job
    openqa-cli api --json --data '{"group_id":1}' -X PUT jobs/639172

    # Change group id for job (pipe JSON data)
    echo '{"group_id":1}' | openqa-cli api --json -X PUT jobs/639172

    # Post job template
    openqa-cli api -X POST job_templates_scheduling/1 \
      schema=JobTemplates-01.yaml preview=0 template="$(cat foo.yaml)"

    # Post job template (from file)
    openqa-cli api -X POST job_templates_scheduling/1 \
      schema=JobTemplates-01.yaml preview=0 --param-file template=foo.yaml

    # Post job template (from JSON file)
    openqa-cli api --data-file form.json -X POST job_templates_scheduling/1

  Options:
        --apibase <path>          API base, defaults to /api/v1
        --apikey <key>            API key
        --apisecret <secret>      API secret
    -a, --header <name:value>     One or more additional HTTP headers
    -D, --data-file <path>        Load content to send with request from file
    -d, --data <string>           Content to send with request, alternatively
                                  you can also pipe data to openqa-cli
    -f, --form                    Turn JSON object into form parameters
        --host <host>             Target host, defaults to http://localhost
    -h, --help                    Show this summary of available options
    -j, --json                    Request content is JSON
        --osd                     Set target host to http://openqa.suse.de
        --o3                      Set target host to https://openqa.opensuse.org
        --param-file <param=file> Load content of params from files instead of
                                  from command line arguments. Multiple params
                                  may be specified by adding the option
                                  multiple times
    -p, --pretty                  Pretty print JSON content
    -q, --quiet                   Do not print error messages to STDERR
    -r, --retries <retries>       Retry up to the specified value on some
                                  errors. Retries can also be set by the
                                  environment variable 'OPENQA_CLI_RETRIES',
                                  defaults to no retry.
                                  Set 'OPENQA_CLI_RETRY_SLEEP_TIME_S' to
                                  configure the sleep time between retries.
    -X, --method <method>         HTTP method to use, defaults to GET
    -v, --verbose                 Print HTTP response headers

=cut
