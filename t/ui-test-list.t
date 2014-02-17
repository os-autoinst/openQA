BEGIN { unshift @INC, 'lib', 'lib/OpenQA/modules'; }

use Mojo::Base -strict;

use Test::More;
use Test::Mojo;
use openqa;
use OpenQA::Test::Database;

my $schema = OpenQA::Test::Database->new->create(Schema => $ENV{OPENQA_DB});

my $t = Test::Mojo->new('OpenQA');
$t->get_ok('/tests')->status_is(200)->content_like(qr/Test results/i, 'result list is there');

$t->get_ok('/tests')->status_is(200)->element_exists('#results')->content_like(qr/scheduled/i);



done_testing();
