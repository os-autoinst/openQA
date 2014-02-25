BEGIN {
  unshift @INC, 'lib', 'lib/OpenQA/modules';
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use OpenQA::Test::Case;

OpenQA::Test::Case->new->init_data;

my $t = Test::Mojo->new('OpenQA');

my $token = $t->ua->get('/tests')->res->dom->at('meta[name=csrf-token]')->attr('content');

ok($token =~ /[0-9a-z]{40}/, "csrf token in meta tag");
#say "csrf token is $token";

is($token, $t->ua->get('/tests')->res->dom->at('form input[name=csrf_token]')->{value}, "token is the same in form");

# Test 99928 is scheduled, so can be canceled. Make sure link contains csrf
# token
is($t->ua->get('/tests')->res->dom->at('#results #job_99928 .cancel a'),
    sprintf ('<a data-method="post" href="/tests/99928/cancel?csrf_token=%s">cancel</a>', $token),
    'CSRF token present in links');

# test cancel with and without CSRF token
$t->post_ok('/tests/99928/cancel' => form => { csrf_token => 'foobar' })
    ->status_is(403);
$t->post_ok('/tests/99928/cancel' => { 'X-CSRF-Token' => $token } => form => {})
    ->status_is(200);
$t->post_ok('/tests/99928/cancel' => form => { csrf_token => $token })
    ->status_is(200);

# test restart with and without CSRF token
$t->post_ok('/tests/99928/restart' => form => { csrf_token => 'foobar' })
    ->status_is(403);
$t->post_ok('/tests/99928/restart' => { 'X-CSRF-Token' => $token } => form => {})
    ->status_is(200);
$t->post_ok('/tests/99928/restart' => form => { csrf_token => $token })
    ->status_is(200);

# test restart with and without CSRF token
$t->post_ok('/tests/99928/setpriority/33' => form => { csrf_token => 'foobar' })
    ->status_is(403);
$t->post_ok('/tests/99928/setpriority/34' => { 'X-CSRF-Token' => $token } => form => {})
    ->status_is(200);
$t->post_ok('/tests/99928/setpriority/35' => form => { csrf_token => $token })
    ->status_is(200);

done_testing();
