package OpenQA::Parser::Result::LTP::Environment;
use Mojo::Base 'OpenQA::Parser::Result';

has [qw(gcc product revision kernel ltp_version harness libc arch)];

sub to_hash {
    {
        gcc         => $_[0]->gcc(),
        product     => $_[0]->product(),
        revision    => $_[0]->revision(),
        kernel      => $_[0]->kernel(),
        ltp_version => $_[0]->ltp_version(),
        harness     => $_[0]->harness(),
        libc        => $_[0]->libc(),
        arch        => $_[0]->arch()};
}

1;
