BEGIN {
  unshift @INC, 'lib', 'lib/OpenQA/modules';
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use OpenQA::Test::Database;

OpenQA::Test::Database->new->create();

my $t = Test::Mojo->new('OpenQA');
$t->get_ok('/tests')->status_is(200)->content_like(qr/Test results/i, 'result list is there');

$t->get_ok('/tests')->status_is(200)->element_exists('#results')->content_like(qr/scheduled/i);

done_testing();
