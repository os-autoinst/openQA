BEGIN {
  unshift @INC, 'lib', 'lib/OpenQA/modules';
}

use Mojo::Base -strict;
use Test::More tests => 15;
use Test::Mojo;
use OpenQA::Test::Case;

OpenQA::Test::Case->new->init_data;

my $t = Test::Mojo->new('OpenQA');

#
# List with no parameters
#
my $get = $t->get_ok('/tests')->status_is(200);
$get->content_like(qr/Test results/i, 'result list is there');

# Test 99946 is successful (30/0/1)
$get->element_exists('#results #job_99946 .extra');
$get->text_is('#results #job_99946 .extra span' => 'textmode');
$get->text_is('#results #job_99946 .overviewok' => '30');
$get->text_is('#results #job_99946 .overviewfail' => '1');

# Test 99963 is still running
ok($get->tx->res->dom->at('#results #job_99963 td.link a') eq '<a href="/tests/99963">testing</a>');

# Test 99928 is scheduled (so can be canceled)
$get->text_is('#results #job_99928 .link' => 'scheduled');
$get->element_exists('#results #job_99928 .cancel');

# Test 99937 is too old to be displayed by default
$get->element_exists_not('#results #job_99937');

#
# List with a limit of 200h
#
$get = $t->get_ok('/tests' => form => {hours => 200})->status_is(200);

# Test 99937 is displayed now
$get->element_exists('#results #job_99937');
$get->text_is('#results #job_99937 .overviewok' => '48');

done_testing();
