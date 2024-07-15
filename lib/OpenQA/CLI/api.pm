# Copyright 2020-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CLI::api;
use Mojo::Base 'OpenQA::Command', -signatures;

use Mojo::File 'path';
use Mojo::JSON qw(decode_json);
use Mojo::Util qw(getopt);
use File::stat;
use File::Basename;
use OpenQA::Constants qw(JOBS_OVERVIEW_SEARCH_CRITERIA);
use OpenQA::Log qw(log_info log_debug log_warning log_error);
use IPC::Run3 qw(run3);

has description => 'Issue an arbitrary request to the API';
has usage => sub {
    my $search_criteria = join(', ', JOBS_OVERVIEW_SEARCH_CRITERIA);
    shift->extract_usage =~ s/\$search_criteria/$search_criteria/r;
};


sub command ($self, @args) {

    my $data = $self->data_from_stdin;

    die $self->usage
      unless getopt \@args,
      'a|header=s' => \my @headers,
      'D|data-file=s' => \my $data_file,
      'd|data=s' => \$data,
      'f|form' => \my $form,
      'j|json' => \my $json,
      'pre-script-hook=s' => \my $prehooksrc,
      'post-script-hook=s' => \my $posthooksrc,
      'param-file=s' => \my @param_file,
      'r|retries=i' => \my $retries,
      'X|method=s' => \(my $method = 'GET');

    @args = $self->decode_args(@args);
    die $self->usage unless my $path = shift @args;

    my $params;
    my @data;
    if ($prehooksrc) {

	$self->_run_script ($_) for path($posthooksrc)->list->grep(qr/post_/)->each;
	#my $hookdata = path($prehooksrc)->slurp;
	#$data = ($hookdata);
	#my $hookparams = decode_json($data);
	#my $argsparams = $self->parse_params(\@args, \@param_file);
	#$params = {%$hookparams, %$argsparams};
    }
    
    $data = path($data_file)->slurp if $data_file;
    @data = ($data);
    $params = $form ? decode_json($data) : $self->parse_params(\@args, \@param_file);
    use Data::Dumper;
    @data = (form => $params) if keys %$params;
    print Dumper(@data[1]);
    if ($posthooksrc) {
	use Data::Dumper;
	# say for path('/home/sri/myapp')->list->each;
	# run_script check exec permissions
	$self->_run_script ($_, $data[1]) for path($posthooksrc)->list->grep(qr/post_/)->each;
	say '_run_script returns ' . Dumper @data;
    }
    die "we got to the end";
    my $headers = $self->parse_headers(@headers);
    $headers->{Accept} //= 'application/json';
    $headers->{'Content-Type'} = 'application/json' if $json;
    my $url = $self->url_for($path);
    my $client = $self->client($url);
    my $tx = $client->build_tx($method, $url, $headers, @data);
    $self->retry_tx($client, $tx, $retries);
}


sub _run_script ($self, $hook_path, $data) {
    my $hook_fl = basename($hook_path);
    return unless ($hook_fl =~ /^(pre|post)_/);
    my $info    = stat($hook_path) or die "path doesnt exist $hook_path : $!";
    unless (-x $info) {
	log_info $_ . ' is not executable';
	return;
    }
    log_info $_ . ' is called';
    eval {
	print 'TST ';
	# https://stackoverflow.com/a/54500161/1462096
	#my @out = qx($hook_path);
	#print '@out ';
	my ($out, $err);
	my @out = run3([$hook_path, $data], \$out, \$err);
	print 'This is out ' . Dumper $out;
	print 'This is err ' . Dumper $err;
    };
    log_error "$@" if $@;
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
    # supported search criteria: $search_criteria
    openqa-cli api --osd jobs/overview groupid=135 distri=caasp version=3.0

    # Restart a job
    openqa-cli api -X POST jobs/16/restart

    # Delete job (CAUTION: destructive operation)
    openqa-cli api --host openqa.example.com -X DELETE jobs/1

    # Trigger a single job
    openqa-cli api -X POST jobs ISO=foo.iso DISTRI=my-distri \
      FLAVOR=my-flavor VERSION=42 BUILD=42 TEST=my-test

    # Trigger a single set of jobs (see
    # https://open.qa/docs/#_spawning_single_new_jobs_jobs_post for details)
    openqa-cli api -X POST jobs \
      TEST:0=first-job TEST:1=second-job _START_AFTER:1=0

    # Trigger jobs on ISO "foo.iso" creating a "scheduled product" (see
    # https://open.qa/docs/#_spawning_multiple_jobs_based_on_templates_isos_post
    # for details, e.g for considering to use the `async` flag)
    openqa-cli api --o3 -X POST isos ISO=foo.iso \
      DISTRI=my-distri FLAVOR=my-flavor ARCH=my-arch VERSION=42 BUILD=1234

    # Track scheduled product
    openqa-cli api --o3 isos/1234

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
    openqa-cli api -f --data-file form.json -X POST job_templates_scheduling/1

  Options:
        --apibase <path>          API base, defaults to /api/v1
        --apikey <key>            API key
        --apisecret <secret>      API secret
    -a, --header <name:value>     One or more additional HTTP headers
    -D, --data-file <path>        Load content to send with request from file.
                                  Works with when -f is provided
    -d, --data <string>           Content to send with request, alternatively
                                  you can also pipe data to openqa-cli
    -f, --form                    Turn JSON object into form parameters
        --host <host>             Target host, defaults to http://localhost
    -H, --hook-scripts            Use a hook script!! TDB
    -h, --help                    Show this summary of available options
    -j, --json                    Request content is JSON
        --osd                     Set target host to http://openqa.suse.de
        --o3                      Set target host to https://openqa.opensuse.org
        --param-file <param=file> Load content of params from files instead of
                                  from command line arguments. Multiple params
                                  may be specified by adding the option
                                  multiple times
    -L, --links                   Print pagination links to STDERR
        --name <name>             Name of this client, used by openQA to
                                  identify different clients via User-Agent
                                  header, defaults to "openqa-cli"
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
