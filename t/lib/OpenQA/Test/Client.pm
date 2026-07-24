package OpenQA::Test::Client;
use Mojo::Base -base, -signatures;
use Test::Mojo;
use OpenQA::Client;

use Exporter 'import';

our @EXPORT_OK = qw(client);

# setup test application with API access
# note: Test::Mojo looses its app when setting a new ua (see https://github.com/kraih/mojo/issues/598).
sub client ($t, @args) {
    $t //= Test::Mojo->new;
    @args = @args ? @args : (apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02');
    my $app = $t->app;
    $t->ua(OpenQA::Client->new(@args)->ioloop(Mojo::IOLoop->singleton));
    $t->app($app);
    return $t;
}

1;
