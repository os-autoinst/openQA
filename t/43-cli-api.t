# Copyright 2020-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later.

use Mojo::Base -strict;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";

use Test::More;
use Capture::Tiny qw(capture capture_stdout);
use Mojo::Server::Daemon;
use Mojo::JSON qw(decode_json);
use Mojo::File qw(tempfile);
use Mojo::Util qw(encode);
use OpenQA::CLI;
use OpenQA::CLI::api;
use OpenQA::Test::Case;
use OpenQA::Test::TimeLimit '10';

OpenQA::Test::Case->new->init_data(fixtures_glob => '03-users.pl');

# Mock WebAPI with extra test routes
my $daemon = Mojo::Server::Daemon->new(listen => ['http://127.0.0.1']);
my $app = $daemon->build_app('OpenQA::WebAPI');
$app->log->level('error');
my $port = $daemon->start->ports->[0];
my $host = "http://127.0.0.1:$port";

# Test routes
my $op = $app->routes->find('api_ensure_operator');
$op->get('/test/op/hello' => sub { shift->render(text => 'Hello operator!') });
my $pub = $app->routes->find('api_public');
$pub->any(
    '/test/pub/http' => sub {
        my $c = shift;
        my $req = $c->req;
        my $data = {
            method => $req->method,
            headers => $req->headers->to_hash,
            params => $req->params->to_hash,
            body => $req->body
        };
        $c->render(json => $data);
    });
$pub->any(
    '/test/pub/error' => [format => ['json']] => {format => 'html'} => sub {
        my $c = shift;
        my $status = $c->param('status') // 500;
        $c->respond_to(
            json => {status => $status, json => {error => $status}},
            any => {status => $status, data => "Error: $status"});
    });

# Default options for mock server
my @host = ('--host', $host);

# Default options for authentication tests
my @auth = ('--apikey', 'ARTHURKEY01', '--apisecret', 'EXCALIBUR', @host);

$ENV{OPENQA_CLI_RETRY_SLEEP_TIME_S} = 0;
my $cli = OpenQA::CLI->new;
my $api = OpenQA::CLI::api->new;

subtest 'Help' => sub {
    my ($stdout, $stderr, @result) = capture sub { $cli->run('help', 'api') };
    like $stdout, qr/Usage: openqa-cli api/, 'help';
};

subtest 'Defaults' => sub {
    my $api = OpenQA::CLI::api->new;
    is $api->apibase, '/api/v1', 'apibase';
    is $api->apikey, undef, 'no apikey';
    is $api->apisecret, undef, 'no apisecret';
    is $api->host, 'http://localhost', 'host';
};

subtest 'Host' => sub {
    my $api = OpenQA::CLI::api->new;
    eval { $api->run('--host', 'openqa.example.com') };
    like $@, qr/Usage: openqa-cli api/, 'usage';
    is $api->host, 'https://openqa.example.com', 'host';

    eval { $api->run('--host', 'http://openqa.example.com') };
    like $@, qr/Usage: openqa-cli api/, 'usage';
    is $api->host, 'http://openqa.example.com', 'host';

    eval { $api->run('--osd') };
    like $@, qr/Usage: openqa-cli api/, 'usage';
    is $api->host, 'http://openqa.suse.de', 'host';

    eval { $api->run('--o3') };
    like $@, qr/Usage: openqa-cli api/, 'usage';
    is $api->host, 'https://openqa.opensuse.org', 'host';

    eval { $api->run(@host) };
    like $@, qr/Usage: openqa-cli api/, 'usage';
    is $api->host, $host, 'host';
};

subtest 'API' => sub {
    my $api = OpenQA::CLI::api->new;
    eval { $api->run('--apibase', '/foo/bar') };
    like $@, qr/Usage: openqa-cli api/, 'usage';
    is $api->apibase, '/foo/bar', 'apibase';

    eval { $api->run(@auth) };
    like $@, qr/Usage: openqa-cli api/, 'usage';
    is $api->apikey, 'ARTHURKEY01', 'apikey';
    is $api->apisecret, 'EXCALIBUR', 'apisecret';
};

subtest 'Client' => sub {
    isa_ok $api->client(Mojo::URL->new('http://localhost')), 'OpenQA::Client', 'right class';
};

subtest 'Unknown options' => sub {
    my $api = OpenQA::CLI::api->new;
    my $buffer = '';
    {
        open my $handle, '>', \$buffer;
        local *STDERR = $handle;
        eval { $api->run('--unknown') };
        like $@, qr/Usage: openqa-cli api/, 'unknown option';
    }
    like $buffer, qr/Unknown option: unknown/, 'right output';
};

subtest 'Simple request with authentication' => sub {
    my ($stdout, $stderr, @result) = capture sub { $api->run(@host, 'test/op/hello') };
    is_deeply \@result, [1], 'non-zero exit code';
    like $stderr, qr/403/, 'not authenticated';
    like $stdout, qr/403/, 'not authenticated';

    ($stdout, $stderr, @result) = capture sub { $api->run(@host, '-q', 'test/op/hello') };
    is_deeply \@result, [1], 'non-zero exit code';
    is $stderr, '', 'quiet';
    like $stdout, qr/403/, 'not authenticated';

    ($stdout, $stderr, @result) = capture sub { $api->run(@host, '--quiet', 'test/op/hello') };
    is_deeply \@result, [1], 'non-zero exit code';
    is $stderr, '', 'quiet';
    like $stdout, qr/403/, 'not authenticated';

    ($stdout, @result) = capture_stdout sub { $api->run(@auth, 'test/op/hello') };
    is_deeply \@result, [0], 'zero exit code';
    unlike $stdout, qr/200 OK.*Content-Type:/s, 'not verbose';
    like $stdout, qr/Hello operator!/, 'operator response';

    ($stdout, @result) = capture_stdout sub { $api->run(@auth, '--verbose', 'test/op/hello') };
    is_deeply \@result, [0], 'zero exit code';
    like $stdout, qr/200 OK.*Content-Type:/s, 'verbose';
    like $stdout, qr/Hello operator!/, 'operator response';

    ($stdout, @result) = capture_stdout sub { $api->run(@auth, '--v', 'test/op/hello') };
    is_deeply \@result, [0], 'zero exit code';
    like $stdout, qr/200 OK.*Content-Type:/s, 'verbose';
    like $stdout, qr/Hello operator!/, 'operator response';
};

subtest 'HTTP features' => sub {
    my ($stdout, @result) = capture_stdout sub { $api->run('--host', $host, 'test/pub/http') };
    my $data = decode_json $stdout;
    is $data->{method}, 'GET', 'GET request';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{method}, 'GET', 'GET request';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '/test/pub/http') };
    $data = decode_json $stdout;
    is $data->{method}, 'GET', 'GET request';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '-X', 'POST', 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '-X=POST', 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '--method', 'POST', 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '--method=POST', 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '-d', 'Hello openQA!', 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{body}, 'Hello openQA!', 'request body';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '--data', 'Hello openQA!', 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{body}, 'Hello openQA!', 'request body';

    ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '-a', 'X-Test: works', 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{headers}{'X-Test'}, 'works', 'X-Test header';

    ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '--header', 'X-Test: works', 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{headers}{'X-Test'}, 'works', 'X-Test header';

    ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '-a', 'X-Test: works', '-a', 'X-Test2: works too', 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{headers}{'X-Test'}, 'works', 'X-Test header';
    is $data->{headers}{'X-Test2'}, 'works too', 'X-Test2 header';

    ($stdout, @result)
      = capture_stdout
      sub { $api->run(@host, '--header', 'X-Test: works', '--header', 'X-Test2: works too', 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{headers}{'X-Test'}, 'works', 'X-Test header';
    is $data->{headers}{'X-Test2'}, 'works too', 'X-Test2 header';

    ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '-X', 'POST', '-a', 'Accept: application/json', 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';
    is $data->{headers}{'Accept'}, 'application/json', 'Accept header';
};

subtest 'Parameters' => sub {
    my ($stdout, @result) = capture_stdout sub { $api->run(@host, 'test/pub/http', 'FOO=bar', 'BAR=baz') };
    my $data = decode_json $stdout;
    is $data->{method}, 'GET', 'GET request';
    is_deeply $data->{params}, {FOO => 'bar', BAR => 'baz'}, 'params';
    is $data->{body}, '', 'no request body';

    ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '-X', 'POST', 'test/pub/http', encode('UTF-8', 'foo=some täst')) };
    $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';
    is_deeply $data->{params}, {foo => 'some täst'}, 'params';
    is $data->{body}, 'foo=some+t%C3%A4st', 'request body';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '-X', 'POST', 'test/pub/http', 'FOO=bar', 'BAR=baz') };
    $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';
    is_deeply $data->{params}, {FOO => 'bar', BAR => 'baz'}, 'params';
    is $data->{body}, 'BAR=baz&FOO=bar', 'request body';

    ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '-X', 'POST', 'test/pub/http', 'FOO=bar', "BAR=baz\n  ya\"d\"a\n1 2 3") };
    $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';
    is_deeply $data->{params}, {FOO => 'bar', BAR => "baz\n  ya\"d\"a\n1 2 3"}, 'params';
    is $data->{body}, 'BAR=baz%0A++ya%22d%22a%0A1+2+3&FOO=bar', 'request body';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, 'test/pub/http', 'invalid') };
    $data = decode_json $stdout;
    is $data->{method}, 'GET', 'GET request';
    is_deeply $data->{params}, {}, 'no params';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '-X', 'POST', 'test/pub/http', 'invalid') };
    $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';
    is_deeply $data->{params}, {}, 'no params';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, 'test/pub/http', 'valid=1') };
    $data = decode_json $stdout;
    is $data->{method}, 'GET', 'GET request';
    is_deeply $data->{params}, {valid => '1'}, 'params';

    ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '-X', 'POST', 'test/pub/http', 'jobs=1611', 'jobs=1610') };
    $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';
    is_deeply $data->{params}, {jobs => [1611, 1610]}, 'params';
    is $data->{body}, 'jobs=1611&jobs=1610', 'request body';

    ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '-X', 'POST', 'test/pub/http', 'test1=', 'test2=3') };
    $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';
    is_deeply $data->{params}, {test1 => '', test2 => 3}, 'params';
    is $data->{body}, 'test1=&test2=3', 'request body';

    ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '-X', 'POST', 'test/pub/http', 'jobs=1611', 'foo=bar', 'jobs=1610') };
    $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';
    is_deeply $data->{params}, {foo => 'bar', jobs => [1611, 1610]}, 'params';
    is $data->{body}, 'foo=bar&jobs=1611&jobs=1610', 'request body';
};

subtest 'JSON' => sub {
    my ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '-d', '{"foo":"bar"}', '-X', 'PUT', 'test/pub/http') };
    my $data = decode_json $stdout;
    is $data->{method}, 'PUT', 'PUT request';
    is $data->{headers}{Accept}, 'application/json', 'Accept header';
    is $data->{headers}{'Content-Type'}, undef, 'no Content-Type header';
    is $data->{body}, '{"foo":"bar"}', 'request body';

    ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '-j', '-d', '{"foo":"bar"}', '-X', 'PUT', 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{method}, 'PUT', 'PUT request';
    is $data->{headers}{Accept}, 'application/json', 'Accept header';
    is $data->{headers}{'Content-Type'}, 'application/json', 'Content-Type header';
    is $data->{body}, '{"foo":"bar"}', 'request body';

    my $json = encode('UTF-8', '{"foo":"some täst"}');
    ($stdout, @result) = capture_stdout sub { $api->run(@host, '-j', '-d', $json, '-X', 'PUT', 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{method}, 'PUT', 'PUT request';
    is $data->{headers}{Accept}, 'application/json', 'Accept header';
    is $data->{headers}{'Content-Type'}, 'application/json', 'Content-Type header';
    is $data->{body}, $json, 'request body';
    is_deeply decode_json($data->{body}), {foo => 'some täst'}, 'unicode roundtrip';

    ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '--json', '-d', '{"foo":"bar"}', '-X', 'PUT', 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{method}, 'PUT', 'PUT request';
    is $data->{headers}{Accept}, 'application/json', 'Accept header';
    is $data->{headers}{'Content-Type'}, 'application/json', 'Content-Type header';
    is $data->{body}, '{"foo":"bar"}', 'request body';

    ($stdout, @result)
      = capture_stdout
      sub { $api->run(@host, '-j', '-d', '{"foo":"bar"}', '-a', 'Accept: text/plain', '-X', 'PUT', 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{method}, 'PUT', 'PUT request';
    is $data->{headers}{Accept}, 'text/plain', 'Accept header';
    is $data->{headers}{'Content-Type'}, 'application/json', 'Content-Type header';
    is $data->{body}, '{"foo":"bar"}', 'request body';
};

subtest 'JSON form data' => sub {
    my ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '-d', '{"foo":"bar"}', '-X', 'POST', 'test/pub/http') };
    my $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';
    is_deeply $data->{params}, {}, 'no params';
    is $data->{body}, '{"foo":"bar"}', 'request body';

    ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '-f', '-d', '{"foo":"bar"}', 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{method}, 'GET', 'GET request';
    is_deeply $data->{params}, {foo => 'bar'}, 'params';
    is $data->{body}, '', 'no request body';

    ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '-f', '-d', '{"foo":"bar"}', '-X', 'POST', 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';
    is_deeply $data->{params}, {foo => 'bar'}, 'params';
    is $data->{body}, 'foo=bar', 'request body';

    ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '--form', '-d', '{"foo":"bar"}', '-X', 'PUT', 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{method}, 'PUT', 'PUT request';
    is_deeply $data->{params}, {foo => 'bar'}, 'params';
    is $data->{body}, 'foo=bar', 'request body';

    my $json = encode('UTF-8', '{"foo":"some täst"}');
    ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '-f', '-d', $json, 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{method}, 'GET', 'GET request';
    is_deeply $data->{params}, {foo => 'some täst'}, 'params';
    is $data->{body}, '', 'no request body';
};

subtest 'Data file' => sub {
    my $file = tempfile->spurt('Hello from a file!');
    my ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '-D', "$file", '-X', 'POST', 'test/pub/http') };
    my $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';
    is_deeply $data->{params}, {}, 'no params';
    is $data->{body}, 'Hello from a file!', 'request body';

    $file->spurt('{"foo":"bar"}');
    ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '--form', '-D', "$file", '-X', 'PUT', 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{method}, 'PUT', 'PUT request';
    is_deeply $data->{params}, {foo => 'bar'}, 'params';
    is $data->{body}, 'foo=bar', 'request body';

    ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '-f', '-D', "$file", 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{method}, 'GET', 'GET request';
    is_deeply $data->{params}, {foo => 'bar'}, 'params';
    is $data->{body}, '', 'no request body';

    ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '-D', "$file", '-X', 'PUT', 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{method}, 'PUT', 'PUT request';
    is_deeply $data->{params}, {}, 'no params';
    is $data->{body}, '{"foo":"bar"}', 'request body';

    $file->spurt(encode('UTF-8', '{"foo":"some täst"}'));
    ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '-f', '-D', "$file", '-X', 'PUT', 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{method}, 'PUT', 'PUT request';
    is_deeply $data->{params}, {foo => 'some täst'}, 'params';
    is $data->{body}, 'foo=some+t%C3%A4st', 'request body';

    $file->spurt(encode('UTF-8', '{"foo":"some täst"}'));
    ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '-f', '-D', "$file", 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{method}, 'GET', 'GET request';
    is_deeply $data->{params}, {foo => 'some täst'}, 'params';
    is $data->{body}, '', 'request body';
};

subtest 'Content negotiation and errors' => sub {
    my ($stdout, $stderr, @result)
      = capture sub { $api->run(@host, '-a', 'Accept: */*', 'test/pub/error') };
    is_deeply \@result, [1], 'non-zero exit code';
    like $stderr, qr/500 Internal Server Error/, 'right error';
    unlike $stdout, qr/500 Internal Server Error/, 'not on STDOUT';
    is $stdout, "Error: 500\n", 'request body';
    unlike $stderr, qr/Error: 500/, 'not on STDERR';

    ($stdout, $stderr, @result)
      = capture sub { $api->run(@host, '-a', 'Accept: */*', 'test/pub/error', 'status=400') };
    is_deeply \@result, [1], 'non-zero exit code';
    like $stderr, qr/400 Bad Request/, 'right error';
    is $stdout, "Error: 400\n", 'request body';

    ($stdout, $stderr, @result)
      = capture sub { $api->run(@host, '-a', 'Accept: */*', '-q', 'test/pub/error', 'status=400') };
    unlike $stderr, qr/400 Bad Request/, 'quiet';
    is $stdout, "Error: 400\n", 'request body';

    ($stdout, $stderr, @result)
      = capture sub { $api->run(@host, '-a', 'Accept: */*', 'test/pub/error', 'status=200') };
    is $stderr, '', 'no error';
    is $stdout, "Error: 200\n", 'request body';

    ($stdout, $stderr, @result)
      = capture sub { $api->run(@host, 'test/pub/error', 'status=200') };
    is $stderr, '', 'no error';
    is $stdout, <<'EOF', 'request body';
{"error":"200"}
EOF
    my @params = (@host, '-a', 'Accept: */*', 'test/pub/error', 'status=502');
    ($stdout, $stderr, @result) = capture sub { $api->run(@params) };
    like $stderr, qr/502 Bad Gateway/, 'aborts on any error, no retries by default';
    is $stdout, "Error: 502\n", 'request body';

    ($stdout, $stderr, @result) = capture sub { $api->run('--retries', '1', @params) };
    like $stdout, qr/failed.*retrying/, 'requests are retried on error if requested';
};

subtest 'Pretty print JSON' => sub {
    my ($stdout, @result)
      = capture_stdout sub { $api->run(@host, 'test/pub/error', 'status=200') };
    is $stdout, <<'EOF', 'request body';
{"error":"200"}
EOF

    ($stdout, @result)
      = capture_stdout sub { $api->run(@host, 'test/pub/error', '-p', 'status=200') };
    is $stdout, <<'EOF', 'request body';
{
   "error" : "200"
}
EOF

    ($stdout, @result)
      = capture_stdout sub { $api->run(@host, 'test/pub/error', '--pretty', 'status=200') };
    is $stdout, <<'EOF', 'request body';
{
   "error" : "200"
}
EOF
};

subtest 'PIPE input' => sub {
    my $file = tempfile;
    my $fh = $file->spurt('Hello openQA!')->open('<');
    local *STDIN = $fh;
    my ($stdout, @result) = capture_stdout sub { $api->run(@host, 'test/pub/http') };
    my $data = decode_json $stdout;
    is $data->{body}, 'Hello openQA!', 'request body';
};

subtest 'YAML Templates' => sub {
    my ($stdout, $stderr, @result) = capture sub { $api->run(@host, '-X', 'POST', 'job_groups', 'name=Test'); };
    my $data = decode_json $stdout;
    is $data->{id}, '1', 'create job group';
    is_deeply \@result, [0], 'create job group - exit code';
    is $stderr, '', 'create job group - stderr quiet';
    my $yaml_text = "products: {}\nscenarios: {}";
    ($stdout, $stderr, @result) = capture sub {
        $api->run(@host, '-X', 'POST', 'job_templates_scheduling/1', 'schema=JobTemplates-01.yaml', 'preview=1',
            "template=$yaml_text");
    };
    $data = decode_json $stdout;
    is $data->{job_group_id}, '1', 'YAML template as param';
    is_deeply \@result, [0], 'YAML template as param - exit code';
    is $stderr, '', 'YAML template as param - stderr quiet';
    my $file = tempfile->spurt($yaml_text);
    ($stdout, $stderr, @result) = capture sub {
        $api->run(@host, '-X', 'POST', 'job_templates_scheduling/1', 'schema=JobTemplates-01.yaml', 'preview=1',
            "template=$file");
    };
    is_deeply \@result, [1], 'File name as template - right error code';
    like $stderr, qr/400 Bad Request/, 'File name as template - right error msg';
    ($stdout, $stderr, @result) = capture sub {
        $api->run(@host, '-X', 'POST', 'job_templates_scheduling/1', 'schema=JobTemplates-01.yaml', 'preview=1',
            '--param-file', "template=$file");
    };
    $data = decode_json $stdout;
    is $data->{job_group_id}, '1', 'YAML template by file';
    is_deeply \@result, [0], 'YAML template by file - exit code';
    is $stderr, '', 'YAML template by file - stderr quiet';
};

done_testing();
