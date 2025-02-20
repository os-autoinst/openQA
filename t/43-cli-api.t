# Copyright 2020-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later.

use Test::Most;
use Test::Warnings qw(:all :report_warnings);
use Mojo::Base -strict, -signatures;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";

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
my $error_count = 0;
$op->get(
    '/test/op/hello' => sub ($c) {
        $c->res->headers->links({next => $c->url_with->query({offset => 5})->to_abs});
        $c->render(text => 'Hello operator!');
    });
my $pub = $app->routes->find('api_public');
$pub->any(
    '/test/pub/http' => sub ($c) {
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
    '/test/pub/error' => [format => ['json']] => {format => 'html'} => sub ($c) {
        my $status_for_error_count = $c->param('status' . ++$error_count);
        my $status = $status_for_error_count // $c->param('status') // 500;
        note "returning status $status response (error count is $error_count)";
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
    like $stdout, qr/supported search criteria: distri, version.*id/, 'search criteria listed';
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
    throws_ok { $api->run('--host', 'openqa.example.com') } qr/Usage: openqa-cli api/, 'usage';
    is $api->host, 'https://openqa.example.com', 'host';

    throws_ok { $api->run('--host', 'http://openqa.example.com') } qr/Usage: openqa-cli api/, 'usage';
    is $api->host, 'http://openqa.example.com', 'host';

    throws_ok { $api->run('--osd') } qr/Usage: openqa-cli api/, 'usage';
    is $api->host, 'http://openqa.suse.de', 'host';

    throws_ok { $api->run('--o3') } qr/Usage: openqa-cli api/, 'usage';
    is $api->host, 'https://openqa.opensuse.org', 'host';

    throws_ok { $api->run(@host) } qr/Usage: openqa-cli api/, 'usage';
    is $api->host, $host, 'host';
};

subtest 'API' => sub {
    my $api = OpenQA::CLI::api->new;
    throws_ok { $api->run('--apibase', '/foo/bar') } qr/Usage: openqa-cli api/, 'usage';
    is $api->apibase, '/foo/bar', 'apibase';

    throws_ok { $api->run(@auth) } qr/Usage: openqa-cli api/, 'usage';
    is $api->apikey, 'ARTHURKEY01', 'apikey';
    is $api->apisecret, 'EXCALIBUR', 'apisecret';
};

subtest 'Client' => sub {
    isa_ok $api->client(Mojo::URL->new('http://localhost')), 'OpenQA::Client', 'right class';
};

subtest 'Unknown options' => sub {
    my $api = OpenQA::CLI::api->new;
    like warning {
        throws_ok { $api->run('--unknown') } qr/Usage: openqa-cli api/, 'unknown option';
    }, qr/Unknown option/, 'warning about unknown option';
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
    my $path = 'test/pub/http';
    my ($stdout, @result) = capture_stdout sub { $api->run('--host', $host, $path) };
    is decode_json($stdout)->{method}, 'GET', 'GET request';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, $path) };
    is decode_json($stdout)->{method}, 'GET', 'GET request';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '/test/pub/http') };
    is decode_json($stdout)->{method}, 'GET', 'GET request';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '-X', 'POST', $path) };
    is decode_json($stdout)->{method}, 'POST', 'POST request';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '-X=POST', $path) };
    is decode_json($stdout)->{method}, 'POST', 'POST request';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '--method', 'POST', $path) };
    is decode_json($stdout)->{method}, 'POST', 'POST request';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '--method=POST', $path) };
    is decode_json($stdout)->{method}, 'POST', 'POST request';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '-d', 'Hello openQA!', $path) };
    is decode_json($stdout)->{body}, 'Hello openQA!', 'request body';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '--data', 'Hello openQA!', $path) };
    is decode_json($stdout)->{body}, 'Hello openQA!', 'request body';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '-a', 'X-Test: works', $path) };
    my $data = decode_json $stdout;
    is $data->{headers}{'User-Agent'}, 'openqa-cli', 'User-Agent header';
    is $data->{headers}{'X-Test'}, 'works', 'X-Test header';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '--header', 'X-Test: works', $path) };
    $data = decode_json $stdout;
    is $data->{headers}{'User-Agent'}, 'openqa-cli', 'User-Agent header';
    is $data->{headers}{'X-Test'}, 'works', 'X-Test header';

    ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '--header', 'X-Test: works', '--name', 'openqa-whatever', $path) };
    $data = decode_json $stdout;
    is $data->{headers}{'User-Agent'}, 'openqa-whatever', 'User-Agent header';
    is $data->{headers}{'X-Test'}, 'works', 'X-Test header';

    ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '-a', 'X-Test: works', '-a', 'X-Test2: works too', $path) };
    $data = decode_json $stdout;
    is $data->{headers}{'X-Test'}, 'works', 'X-Test header';
    is $data->{headers}{'X-Test2'}, 'works too', 'X-Test2 header';

    ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '--header', 'X-Test: works', '--header', 'X-Test2: works too', $path) };
    $data = decode_json $stdout;
    is $data->{headers}{'X-Test'}, 'works', 'X-Test header';
    is $data->{headers}{'X-Test2'}, 'works too', 'X-Test2 header';

    ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '-X', 'POST', '-a', 'Accept: application/json', $path) };
    $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';
    is $data->{headers}{'Accept'}, 'application/json', 'Accept header';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '-X', 'POST', 'test/pub/http?async=1') };
    $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';
    is_deeply $data->{params}, {async => '1'}, 'Query parameters';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '-X', 'POST', 'test/pub/http?async=1', 'foo=bar') };
    $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';
    is_deeply $data->{params}, {async => '1', foo => 'bar'}, 'Query parameters';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '-X', 'POST', '/test/pub/http?async=1&foo=bar') };
    $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';
    is_deeply $data->{params}, {async => '1', foo => 'bar'}, 'Query parameters';
};

subtest 'Parameters' => sub {
    my $path = 'test/pub/http';
    my ($stdout, @result) = capture_stdout sub { $api->run(@host, $path, 'FOO=bar', 'BAR:=baz') };
    my $data = decode_json $stdout;
    is $data->{method}, 'GET', 'GET request';
    is_deeply $data->{params}, {FOO => 'bar', 'BAR:' => 'baz'}, 'params';
    is $data->{body}, '', 'no request body';

    my @params = (@host, '-X', 'POST', $path);
    ($stdout, @result) = capture_stdout sub { $api->run(@params, encode('UTF-8', 'foo=some täst')) };
    $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';
    is_deeply $data->{params}, {foo => 'some täst'}, 'params';
    is $data->{body}, 'foo=some+t%C3%A4st', 'request body';

    ($stdout, @result) = capture_stdout sub { $api->run(@params, 'FOO=bar', 'BAR=baz') };
    $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';
    is_deeply $data->{params}, {FOO => 'bar', BAR => 'baz'}, 'params';
    is $data->{body}, 'BAR=baz&FOO=bar', 'request body';

    ($stdout, @result) = capture_stdout sub { $api->run(@params, 'FOO=bar', "BAR=baz\n  ya\"d\"a\n1 2 3") };
    $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';
    is_deeply $data->{params}, {FOO => 'bar', BAR => "baz\n  ya\"d\"a\n1 2 3"}, 'params';
    is $data->{body}, 'BAR=baz%0A++ya%22d%22a%0A1+2+3&FOO=bar', 'request body';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, $path, 'invalid') };
    $data = decode_json $stdout;
    is $data->{method}, 'GET', 'GET request';
    is_deeply $data->{params}, {}, 'no params';

    ($stdout, @result) = capture_stdout sub { $api->run(@params, 'invalid') };
    $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';
    is_deeply $data->{params}, {}, 'no params';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, $path, 'valid=1') };
    $data = decode_json $stdout;
    is $data->{method}, 'GET', 'GET request';
    is_deeply $data->{params}, {valid => '1'}, 'params';

    ($stdout, @result) = capture_stdout sub { $api->run(@params, 'jobs=1611', 'jobs=1610') };
    $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';
    is_deeply $data->{params}, {jobs => [1611, 1610]}, 'params';
    is $data->{body}, 'jobs=1611&jobs=1610', 'request body';

    ($stdout, @result) = capture_stdout sub { $api->run(@params, 'test1=', 'test2=3') };
    $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';
    is_deeply $data->{params}, {test1 => '', test2 => 3}, 'params';
    is $data->{body}, 'test1=&test2=3', 'request body';

    ($stdout, @result) = capture_stdout sub { $api->run(@params, 'jobs=1611', 'foo=bar', 'jobs=1610') };
    $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';
    is_deeply $data->{params}, {foo => 'bar', jobs => [1611, 1610]}, 'params';
    is $data->{body}, 'foo=bar&jobs=1611&jobs=1610', 'request body';
};

subtest 'JSON' => sub {
    my $path = 'test/pub/http';
    my @data = ('-d', '{"foo":"bar"}');
    my ($stdout, @result) = capture_stdout sub { $api->run(@host, @data, '-X', 'PUT', $path) };
    my $data = decode_json $stdout;
    is $data->{method}, 'PUT', 'PUT request';
    is $data->{headers}{Accept}, 'application/json', 'Accept header';
    is $data->{headers}{'Content-Type'}, undef, 'no Content-Type header';
    is $data->{body}, '{"foo":"bar"}', 'request body';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '-j', @data, '-X', 'PUT', $path) };
    $data = decode_json $stdout;
    is $data->{method}, 'PUT', 'PUT request';
    is $data->{headers}{Accept}, 'application/json', 'Accept header';
    is $data->{headers}{'Content-Type'}, 'application/json', 'Content-Type header';
    is $data->{body}, '{"foo":"bar"}', 'request body';

    my $json = encode('UTF-8', '{"foo":"some täst"}');
    ($stdout, @result) = capture_stdout sub { $api->run(@host, '-j', '-d', $json, '-X', 'PUT', $path) };
    $data = decode_json $stdout;
    is $data->{method}, 'PUT', 'PUT request';
    is $data->{headers}{Accept}, 'application/json', 'Accept header';
    is $data->{headers}{'Content-Type'}, 'application/json', 'Content-Type header';
    is $data->{body}, $json, 'request body';
    is_deeply decode_json($data->{body}), {foo => 'some täst'}, 'unicode roundtrip';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '--json', @data, '-X', 'PUT', $path) };
    $data = decode_json $stdout;
    is $data->{method}, 'PUT', 'PUT request';
    is $data->{headers}{Accept}, 'application/json', 'Accept header';
    is $data->{headers}{'Content-Type'}, 'application/json', 'Content-Type header';
    is $data->{body}, '{"foo":"bar"}', 'request body';

    my @header = ('-a', 'Accept: text/plain');
    ($stdout, @result) = capture_stdout sub { $api->run(@host, '-j', @data, @header, '-X', 'PUT', $path) };
    $data = decode_json $stdout;
    is $data->{method}, 'PUT', 'PUT request';
    is $data->{headers}{Accept}, 'text/plain', 'Accept header';
    is $data->{headers}{'Content-Type'}, 'application/json', 'Content-Type header';
    is $data->{body}, '{"foo":"bar"}', 'request body';
};

subtest 'JSON form data' => sub {
    my @data = ('-d', '{"foo":"bar"}');
    my $path = 'test/pub/http';
    my ($stdout, @result) = capture_stdout sub { $api->run(@host, @data, '-X', 'POST', $path) };
    my $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';
    is_deeply $data->{params}, {}, 'no params';
    is $data->{body}, '{"foo":"bar"}', 'request body';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '-f', @data, $path) };
    $data = decode_json $stdout;
    is $data->{method}, 'GET', 'GET request';
    is_deeply $data->{params}, {foo => 'bar'}, 'params';
    is $data->{body}, '', 'no request body';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '-f', @data, '-X', 'POST', $path) };
    $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';
    is_deeply $data->{params}, {foo => 'bar'}, 'params';
    is $data->{body}, 'foo=bar', 'request body';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '--form', @data, '-X', 'PUT', $path) };
    $data = decode_json $stdout;
    is $data->{method}, 'PUT', 'PUT request';
    is_deeply $data->{params}, {foo => 'bar'}, 'params';
    is $data->{body}, 'foo=bar', 'request body';

    my $json = encode('UTF-8', '{"foo":"some täst"}');
    ($stdout, @result) = capture_stdout sub { $api->run(@host, '-f', '-d', $json, $path) };
    $data = decode_json $stdout;
    is $data->{method}, 'GET', 'GET request';
    is_deeply $data->{params}, {foo => 'some täst'}, 'params';
    is $data->{body}, '', 'no request body';
};

subtest 'Data file' => sub {
    my $path = 'test/pub/http';
    my $file = tempfile->spew('Hello from a file!');
    my ($stdout, @result) = capture_stdout sub { $api->run(@host, '-D', "$file", '-X', 'POST', $path) };
    my $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';
    is_deeply $data->{params}, {}, 'no params';
    is $data->{body}, 'Hello from a file!', 'request body';

    $file->spew('{"foo":"bar"}');
    ($stdout, @result) = capture_stdout sub { $api->run(@host, '--form', '-D', "$file", '-X', 'PUT', $path) };
    $data = decode_json $stdout;
    is $data->{method}, 'PUT', 'PUT request';
    is_deeply $data->{params}, {foo => 'bar'}, 'params';
    is $data->{body}, 'foo=bar', 'request body';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '-f', '-D', "$file", $path) };
    $data = decode_json $stdout;
    is $data->{method}, 'GET', 'GET request';
    is_deeply $data->{params}, {foo => 'bar'}, 'params';
    is $data->{body}, '', 'no request body';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '-D', "$file", '-X', 'PUT', $path) };
    $data = decode_json $stdout;
    is $data->{method}, 'PUT', 'PUT request';
    is_deeply $data->{params}, {}, 'no params';
    is $data->{body}, '{"foo":"bar"}', 'request body';

    $file->spew(encode('UTF-8', '{"foo":"some täst"}'));
    ($stdout, @result) = capture_stdout sub { $api->run(@host, '-f', '-D', "$file", '-X', 'PUT', $path) };
    $data = decode_json $stdout;
    is $data->{method}, 'PUT', 'PUT request';
    is_deeply $data->{params}, {foo => 'some täst'}, 'params';
    is $data->{body}, 'foo=some+t%C3%A4st', 'request body';

    $file->spew(encode('UTF-8', '{"foo":"some täst"}'));
    ($stdout, @result) = capture_stdout sub { $api->run(@host, '-f', '-D', "$file", $path) };
    $data = decode_json $stdout;
    is $data->{method}, 'GET', 'GET request';
    is_deeply $data->{params}, {foo => 'some täst'}, 'params';
    is $data->{body}, '', 'request body';
};

subtest 'Content negotiation and errors' => sub {
    my @params = (@host, '-a', 'Accept: */*', 'test/pub/error');
    my ($stdout, $stderr, @result) = capture sub { $api->run(@params) };
    is_deeply \@result, [1], 'non-zero exit code';
    like $stderr, qr/500 Internal Server Error/, 'right error';
    unlike $stdout, qr/500 Internal Server Error/, 'not on STDOUT';
    is $stdout, "Error: 500\n", 'request body';
    unlike $stderr, qr/Error: 500/, 'not on STDERR';

    ($stdout, $stderr, @result) = capture sub { $api->run(@params, 'status=400') };
    is_deeply \@result, [1], 'non-zero exit code';
    like $stderr, qr/400 Bad Request/, 'right error';
    is $stdout, "Error: 400\n", 'request body';

    ($stdout, $stderr, @result) = capture sub { $api->run('-q', @params, 'status=400') };
    unlike $stderr, qr/400 Bad Request/, 'quiet';
    is $stdout, "Error: 400\n", 'request body';

    ($stdout, $stderr, @result) = capture sub { $api->run(@params, 'status=200') };
    is $stderr, '', 'no error';
    is $stdout, "Error: 200\n", 'request body';

    ($stdout, $stderr, @result) = capture sub { $api->run(@host, 'test/pub/error', 'status=200') };
    is $stderr, '', 'no error';
    is $stdout, <<'EOF', 'request body';
{"error":"200"}
EOF
    @params = (@params, 'status=502');
    ($stdout, $stderr, @result) = capture sub { $api->run(@params) };
    like $stderr, qr/502 Bad Gateway/, 'aborts on any error, no retries by default';
    is $stdout, "Error: 502\n", 'request body';

    ($stdout, $stderr, @result) = capture sub { $api->run('--retries', '1', @params) };
    like $stdout, qr/Error: 502/s, '(stdout) requests are retried on error if requested';
    like $stderr, qr/failed.*retrying/s, '(stderr) requests are retried on error if requested';
    is $result[0], 1, 'exited with non-zero return code after all retries are exhausted';

    $error_count = 0;
    @params = (@params, 'status2=200');
    ($stdout, $stderr, @result) = capture sub { $api->run('--retries', '1', @params) };
    unlike $stdout, qr/Error: 502/, 'response from failing request suppressed';
    like $stdout, qr/Error: 200/s, '(stdout) request can succeed after failing before';
    like $stderr, qr/failed, hit error 502.*retrying/s, '(stderr) request can succeed after failing before';
    is $result[0], 0, 'exited with zero return code after success on 2nd attempt';

    @params = ('--host', 'http://localhost:123456', '--retries', 1, 'api', 'test');
    ($stdout, $stderr, @result) = capture sub { $api->run(@params) };
    like $stderr, qr/Connection refused/, 'aborts on connection refused';
    like $stderr, qr/failed.*retrying/, 'requests are retried on error if requested';
};

subtest 'Pretty print JSON' => sub {
    my ($stdout, @result) = capture_stdout sub { $api->run(@host, 'test/pub/error', 'status=200') };
    is $stdout, <<'EOF', 'request body';
{"error":"200"}
EOF

    ($stdout, @result) = capture_stdout sub { $api->run(@host, 'test/pub/error', '--pretty', 'status=200') };
    is $stdout, <<'EOF', 'request body';
{
   "error" : "200"
}
EOF
};

subtest 'Pagination links' => sub {
    my ($stdout, $stderr, @result) = capture sub { $api->run(@host, '--links', '/test/op/hello') };
    like $stderr, qr!next:.+/api/v1/test/op/hello\?offset=5!, 'links printed';
    is $stdout, "Hello operator!\n", 'request body';

    ($stdout, $stderr, @result) = capture sub { $api->run(@host, '-L', '/test/op/hello') };
    like $stderr, qr!next:.+/api/v1/test/op/hello\?offset=5!, 'links printed';
    is $stdout, "Hello operator!\n", 'request body';

    $stderr =~ /(http.+offset=5)/;
    my $next = $1;
    ($stdout, $stderr, @result) = capture sub { $api->run(@host, '-L', $next) };
    like $stderr, qr!next:.+/api/v1/test/op/hello\?offset=5!, 'links printed';
    is $stdout, "Hello operator!\n", 'request body';

    ($stdout, $stderr, @result) = capture sub { $api->run(@host, '/test/op/hello') };
    is $stderr, '', 'no links printed';
    is $stdout, "Hello operator!\n", 'request body';
};

subtest 'PIPE input' => sub {
    my $file = tempfile;
    my $fh = $file->spew('Hello openQA!')->open('<');
    local *STDIN = $fh;
    my ($stdout, @result) = capture_stdout sub { $api->run(@host, '--data-file', '-', 'test/pub/http') };
    is decode_json($stdout)->{body}, 'Hello openQA!', 'request body';
};

subtest 'YAML Templates' => sub {
    my ($stdout, $stderr, @result) = capture sub { $api->run(@host, '-X', 'POST', 'job_groups', 'name=Test'); };
    is decode_json($stdout)->{id}, '1', 'create job group';
    is_deeply \@result, [0], 'create job group - exit code';
    is $stderr, '', 'create job group - stderr quiet';
    my $yaml_text = "products: {}\nscenarios: {}";
    my @params = (@host, '-X', 'POST', 'job_templates_scheduling/1', 'schema=JobTemplates-01.yaml', 'preview=1');
    ($stdout, $stderr, @result) = capture sub { $api->run(@params, "template=$yaml_text") };
    is decode_json($stdout)->{job_group_id}, '1', 'YAML template as param';
    is_deeply \@result, [0], 'YAML template as param - exit code';
    is $stderr, '', 'YAML template as param - stderr quiet';
    my $file = tempfile->spew($yaml_text);
    ($stdout, $stderr, @result) = capture sub { $api->run(@params, "template=$file") };
    is_deeply \@result, [1], 'File name as template - right error code';
    like $stderr, qr/400 Bad Request/, 'File name as template - right error msg';
    ($stdout, $stderr, @result) = capture sub { $api->run(@params, '--param-file', "template=$file") };
    is decode_json($stdout)->{job_group_id}, '1', 'YAML template by file';
    is_deeply \@result, [0], 'YAML template by file - exit code';
    is $stderr, '', 'YAML template by file - stderr quiet';
};

subtest 'Base URL with slash' => sub {
    $app->config->{global}->{base_url} = "http://127.0.0.1:$port/";
    my ($stdout, @result) = capture_stdout sub { $api->run(@auth, 'test/op/hello') };
    is_deeply \@result, [0], 'zero exit code';
    unlike $stdout, qr/200 OK.*Content-Type:/s, 'not verbose';
    like $stdout, qr/Hello operator!/, 'operator response';
};

done_testing();
