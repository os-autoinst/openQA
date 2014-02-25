BEGIN {
  unshift @INC, 'lib', 'lib/OpenQA/modules';
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use OpenQA::Test::Case;
use Data::Dump;

OpenQA::Test::Case->new->init_data;

my $t = Test::Mojo->new('OpenQA');

my $headers = {
    Accept => 'application/json'
};

my $ret;

$ret = $t->get_ok('/api/v1/workers');
ok($ret->tx->success, 'listing workers works');
is(ref $ret->tx->res->json, 'HASH', 'workers returned hash');
# just a random check that the structure is sane
is($ret->tx->res->json->{workers}->[1]->{host}, 'localhost', 'worker present');

$ret = $t->get_ok('/api/v1/authenticate');

is($ret->tx->res->code, 204, "default return no content");

$ret = $t->get_ok('/api/v1/authenticate', $headers);

is($ret->tx->res->code, 200, "has content after setting Accept header");

ok($ret->tx->res->json, "json returned");

my $token = $ret->tx->res->json->{token};
like($token, qr/[0-9a-z]{40}/, "token looks good");

$ret = $t->post_ok('/api/v1/workers', $headers, form => {host => 'localhost', instance => 1, backend => 'qemu' });
is($ret->tx->res->code, 403, "register worker without token fails");

$headers->{'X-CSRF-Token'} = $token;

$ret = $t->post_ok('/api/v1/workers', $headers, form => {host => 'localhost', instance => 1, backend => 'qemu' });
is($ret->tx->res->code, 200, "register existing worker with token");
is($ret->tx->res->json->{id}, 1, "worker id is 1");

$ret = $t->post_ok('/api/v1/workers', $headers, form => {host => 'localhost', instance => 42, backend => 'qemu' });
is($ret->tx->res->code, 200, "register new worker");
is($ret->tx->res->json->{id}, 2, "new worker id is 2");

done_testing();
