package OpenQA::FakePlugin::FooFoo;
use Mojo::Base 'Mojolicious::Plugin';
has 'configuration_fields' => sub {
    {
        foofoo => {
            is_there => 1
        }};
};

sub register {
    1;
}
1;
