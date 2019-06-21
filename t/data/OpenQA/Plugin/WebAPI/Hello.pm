package OpenQA::Plugin::WebAPI::Hello;
use Mojo::Base 'Mojolicious::Plugin';
use Cwd 'abs_path';
use File::Basename;

# my $script_dirname = dirname(abs_path(__FILE__));
my $script_dirname = dirname(__FILE__);
my $name;

sub register {
    my ($self, $app, $config) = @_;
    my $prefix = $config->{route} // $app->routes->any('/plugin');
    $prefix->to(return_to => $config->{return_to} // '/');

    $name = $config->{name} // "";

    # Templates
    push @{$app->renderer->paths}, $script_dirname;
    $prefix->get('/hello' => \&_hello_json)->name('Hello_hello');
    $prefix->get('/Hello' => \&_hello_form)->name('Hello_Hello');
}

sub _hello_json {
    my $self = shift;

    $self->render(json => {"msg", "hello world"});
}

sub _hello_form {
    my $self = shift;

    $self->stash('name', $name);
    $self->render('Hello');
}

1;
