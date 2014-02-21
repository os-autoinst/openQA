package OpenQA::Test::Case;

use OpenQA::Test::Database;
use OpenQA::Test::Testresults;
use Mojo::Base -base;
use Date::Format qw/time2str/;

sub init_data {
    # This should result in the 't' directory, even if $0 is in a subdirectory
    my ($tdirname) = $0 =~ qr/((.*\/t\/|^t\/)).+$/;
    my $schema = OpenQA::Test::Database->new->create();

    # ARGL, we can't fake the current time and the db manages
    # t_started so we have to override it manually
    my $r = $schema->resultset("Jobs")->search({ id => 99937 })->update({
            t_created => time2str('%Y-%m-%d %H:%M:%S', time-540000, 'UTC'),  # 150 hours ago;
    });

    OpenQA::Test::Testresults->new->create(directory => $tdirname.'testresults');
}

1;
