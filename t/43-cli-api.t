# Copyright (C) 2020 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>..

use Mojo::Base -strict;

use FindBin;
use lib "$FindBin::Bin/lib";

use Test::More;
use Capture::Tiny qw(capture capture_stdout);
use Mojo::Server::Daemon;
use Mojo::JSON qw(decode_json);
use Mojo::File qw(tempfile);
use OpenQA::CLI;
use OpenQA::CLI::api;
use OpenQA::Test::Case;

OpenQA::Test::Case->new->init_data;

# Mock WebAPI with extra test routes
my $daemon = Mojo::Server::Daemon->new(listen => ['http://127.0.0.1']);
my $app    = $daemon->build_app('OpenQA::WebAPI');
$app->log->level('error');
my $port = $daemon->start->ports->[0];
my $host = "http://127.0.0.1:$port";

# Test routes
my $op = $app->routes->find('api_ensure_operator');
$op->get('/test/op/hello' => sub { shift->render(text => 'Hello operator!') });
my $pub = $app->routes->find('api_public');
$pub->any(
    '/test/pub/http' => sub {
        my $c    = shift;
        my $req  = $c->req;
        my $data = {
            method  => $req->method,
            headers => $req->headers->to_hash,
            params  => $req->params->to_hash,
            body    => $req->body
        };
        $c->render(json => $data);
    });
$pub->any(
    '/test/pub/error' => sub {
        my $c      = shift;
        my $status = $c->param('status') // 500;
        $c->respond_to(
            json => {status => $status, json => {error => $status}},
            any  => {status => $status, data => "Error: $status"});
    });

# Default options for mock server
my @host = ('-H', $host);

# Default options for authentication tests
my @auth = ('--apikey', 'ARTHURKEY01', '--apisecret', 'EXCALIBUR', @host);

my $cli = OpenQA::CLI->new;
my $api = OpenQA::CLI::api->new;

subtest 'Help' => sub {
    my ($stdout, @result) = capture_stdout sub { $cli->run('help', 'api') };
    like $stdout, qr/Usage: openqa-cli api/, 'help';
};

subtest 'Client' => sub {
    isa_ok $api->client, 'OpenQA::Client', 'right class';
};

subtest 'Simple request with authentication' => sub {
    my ($stdout, $stderr, @result) = capture sub { $api->run(@host, 'test/op/hello') };
    like $stderr, qr/403/, 'not authenticated';
    like $stdout, qr/403/, 'not authenticated';

    ($stdout, $stderr, @result) = capture sub { $api->run(@host, '-q', 'test/op/hello') };
    is $stderr,   '',      'quiet';
    like $stdout, qr/403/, 'not authenticated';

    ($stdout, $stderr, @result) = capture sub { $api->run(@host, '--quiet', 'test/op/hello') };
    is $stderr,   '',      'quiet';
    like $stdout, qr/403/, 'not authenticated';

    ($stdout, @result) = capture_stdout sub { $api->run(@auth, 'test/op/hello') };
    like $stdout, qr/Hello operator!/, 'operator response';
};

subtest 'HTTP features' => sub {
    my ($stdout, @result) = capture_stdout sub { $api->run('--host', $host, 'test/pub/http') };
    my $data = decode_json $stdout;
    is $data->{method}, 'GET', 'GET request';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{method}, 'GET', 'GET request';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '-X', 'POST', 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '--method', 'POST', 'test/pub/http') };
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
    is $data->{headers}{'X-Test'},  'works',     'X-Test header';
    is $data->{headers}{'X-Test2'}, 'works too', 'X-Test2 header';

    ($stdout, @result)
      = capture_stdout
      sub { $api->run(@host, '--header', 'X-Test: works', '--header', 'X-Test2: works too', 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{headers}{'X-Test'},  'works',     'X-Test header';
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

    ($stdout, @result) = capture_stdout sub { $api->run(@host, '-X', 'POST', 'test/pub/http', 'FOO=bar', 'BAR=baz') };
    $data = decode_json $stdout;
    is $data->{method}, 'POST', 'POST request';
    is_deeply $data->{params}, {FOO => 'bar', BAR => 'baz'}, 'params';
    is $data->{body}, 'BAR=baz&FOO=bar', 'request body';

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
};

subtest 'JSON' => sub {
    my ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '-d', '{"foo":"bar"}', '-X', 'PUT', 'test/pub/http') };
    my $data = decode_json $stdout;
    is $data->{method}, 'PUT', 'PUT request';
    is $data->{headers}{Accept},         'application/json', 'Accept header';
    is $data->{headers}{'Content-Type'}, undef,              'no Content-Type header';
    is $data->{body}, '{"foo":"bar"}', 'request body';

    ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '-j', '-d', '{"foo":"bar"}', '-X', 'PUT', 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{method}, 'PUT', 'PUT request';
    is $data->{headers}{Accept},         'application/json', 'Accept header';
    is $data->{headers}{'Content-Type'}, 'application/json', 'Content-Type header';
    is $data->{body}, '{"foo":"bar"}', 'request body';

    ($stdout, @result)
      = capture_stdout sub { $api->run(@host, '--json', '-d', '{"foo":"bar"}', '-X', 'PUT', 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{method}, 'PUT', 'PUT request';
    is $data->{headers}{Accept},         'application/json', 'Accept header';
    is $data->{headers}{'Content-Type'}, 'application/json', 'Content-Type header';
    is $data->{body}, '{"foo":"bar"}', 'request body';

    ($stdout, @result)
      = capture_stdout
      sub { $api->run(@host, '-j', '-d', '{"foo":"bar"}', '-a', 'Accept: text/plain', '-X', 'PUT', 'test/pub/http') };
    $data = decode_json $stdout;
    is $data->{method}, 'PUT', 'PUT request';
    is $data->{headers}{Accept},         'text/plain',       'Accept header';
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
};

subtest 'Content negotiation and errors' => sub {
    my ($stdout, $stderr, @result)
      = capture sub { $api->run(@host, '-a', 'Accept: */*', 'test/pub/error') };
    like $stderr,   qr/500 Internal Server Error/, 'right error';
    unlike $stdout, qr/500 Internal Server Error/, 'not on STDOUT';
    is $stdout,     "Error: 500\n",                'request body';
    unlike $stderr, qr/Error: 500/,                'not on STDERR';

    ($stdout, $stderr, @result)
      = capture sub { $api->run(@host, '-a', 'Accept: */*', 'test/pub/error', 'status=400') };
    like $stderr, qr/400 Bad Request/, 'right error';
    is $stdout,   "Error: 400\n",      'request body';

    ($stdout, $stderr, @result)
      = capture sub { $api->run(@host, '-a', 'Accept: */*', '-q', 'test/pub/error', 'status=400') };
    unlike $stderr, qr/400 Bad Request/, 'quiet';
    is $stdout,     "Error: 400\n",      'request body';

    ($stdout, $stderr, @result)
      = capture sub { $api->run(@host, '-a', 'Accept: */*', 'test/pub/error', 'status=200') };
    is $stderr, '',             'no error';
    is $stdout, "Error: 200\n", 'request body';

    ($stdout, $stderr, @result)
      = capture sub { $api->run(@host, 'test/pub/error', 'status=200') };
    is $stderr, '', 'no error';
    is $stdout, <<'EOF', 'request body';
{"error":"200"}
EOF
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
    my $fh   = $file->spurt('Hello openQA!')->open('<');
    local *STDIN = $fh;
    my ($stdout, @result) = capture_stdout sub { $api->run(@host, 'test/pub/http') };
    my $data = decode_json $stdout;
    is $data->{body}, 'Hello openQA!', 'request body';
};

done_testing();
