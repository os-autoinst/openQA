BEGIN { unshift @INC, 'lib', 'lib/OpenQA/modules'; }

use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

my $t = Test::Mojo->new('OpenQA');
$t->get_ok('/')->status_is(200)->content_like(qr/Test result overview/i);

done_testing();
