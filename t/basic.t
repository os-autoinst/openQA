BEGIN { unshift @INC, 'lib', 'lib/WebQA/modules'; }

use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

my $t = Test::Mojo->new('WebQA');
$t->get_ok('/')->status_is(200)->content_like(qr/Test result overview/i);

done_testing();
