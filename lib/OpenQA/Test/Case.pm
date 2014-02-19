package OpenQA::Test::Case;

use OpenQA::Test::Database;
use OpenQA::Test::Testresults;
use Mojo::Base -base;

sub init_data {
    # This should result in the 't' directory, even if $0 is in a subdirectory
    my ($tdirname) = $0 =~ qr/((.*\/t\/|^t\/)).+$/;
    OpenQA::Test::Database->new->create();
    OpenQA::Test::Testresults->new->create(directory => $tdirname.'testresults');
}

1;
