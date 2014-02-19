package OpenQA::Test::Case;

use OpenQA::Test::Database;
use OpenQA::Test::Testresults;
use Mojo::Base -base;

sub init_data {
    OpenQA::Test::Database->new->create();
    OpenQA::Test::Testresults->new->create(directory => 't/testresults');
}

1;
