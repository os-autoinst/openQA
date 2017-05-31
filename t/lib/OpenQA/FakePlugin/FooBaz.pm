package OpenQA::FakePlugin::FooBaz;
use Mojo::Base -base;

sub configuration_fields {
    {
        baz => {
            foo => 1
        }};
}
1;
