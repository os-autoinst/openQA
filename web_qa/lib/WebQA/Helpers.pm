package WebQA::Helpers;

use strict;
use warnings;
use awstandard;

use base 'Mojolicious::Plugin';

sub register {

    my ($self, $app) = @_;
    
    # does not really work with parameters; needs investigation
    $app->helper(AWisodatetime2 =>
                 sub { shift; return AWisodatetime2(@_); });
    
}

1;
