package OpenQA::FakePlugin::Foo;
use Mojo::Base -base;
has 'configuration_fields' => sub {
    {
        auth => {
            method => 1
        }};
};
1;
