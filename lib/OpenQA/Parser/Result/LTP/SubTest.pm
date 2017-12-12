package OpenQA::Parser::Result::LTP::SubTest;
use Mojo::Base 'OpenQA::Parser::Result';

has [qw(log duration result)];

sub to_hash {
    {
        log      => $_[0]->log(),
        duration => $_[0]->duration(),
        result   => $_[0]->result(),
    };
}



1;
