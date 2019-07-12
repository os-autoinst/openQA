package OpenQA::FakePlugin::FooBar;

use strict;
use warnings;

sub configuration_fields {
    {
        bar => {
            foo => 1
        }};
}
1;
