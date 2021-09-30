# Copyright 2017-2018 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Parser::Format::LTP;
use Mojo::Base 'OpenQA::Parser::Format::JUnit';

# Translates to JSON LTP format -> LTP internal representation
# The parser results will be a collection of OpenQA::Parser::Result::LTP::Test
use Carp qw(croak confess);
use Mojo::JSON;
use Storable 'dclone';

has include_results => 1;

sub _add_single_result { shift->results->add(OpenQA::Parser::Result::LTP::Test->new(@_)) }

# Parser
sub parse {
    my ($self, $json) = @_;
    confess "No JSON given/loaded" unless $json;
    my $decoded_json = Mojo::JSON::from_json($json);

    # may be optional since format result_array:v2
    $self->generated_tests_extra->add(OpenQA::Parser::Result::LTP::Environment->new($decoded_json->{environment}))
      if $decoded_json->{environment};

    foreach my $res (@{$decoded_json->{results}}) {
        my $result = dclone $res;
        my $t_name = $res->{test_fqn};
        $t_name =~ s/:/_/g;

        $result->{result} = 'ok';
        $result->{result} = 'fail' if $result->{test}->{result} !~ /pass/i || $result->{status} !~ /pass/i;

        # may be optional since format result_array:v2
        $result->{environment} = OpenQA::Parser::Result::LTP::Environment->new($result->{environment})
          if $res->{environment};
        $t_name =~ s/[\/.]/_/g;    # dots in the filename confuse the web api routes
        $result->{name} = $t_name;

        my $details
          = {result => ($result->{test}->{result} !~ /pass/i || $result->{status} !~ /pass/i) ? 'fail' : 'ok'};
        my $text_fn = "LTP-$t_name.txt";
        my $content = $res->{test}->{log};

        $details->{text} = $text_fn;
        $details->{title} = $t_name;

        push @{$result->{details}}, $details;

        $self->_add_output(
            {
                file => $text_fn,
                content => $content
            });

        my $t = OpenQA::Parser::Result::LTP::SubTest->new(
            flags => {},
            category => 'LTP',
            name => $t_name,
            log => $res->{test}->{log},
            duration => $res->{test}->{duration},
            script => undef,
            result => $res->{test}->{result});
        $self->tests->add($t);
        $result->{test} = $t if $self->include_results();
        $self->_add_single_result($result);
    }

    $self;
}

# Schema
{
    package OpenQA::Parser::Result::LTP::Test;
    use Mojo::Base 'OpenQA::Parser::Result::OpenQA';

    has environment => sub { OpenQA::Parser::Result::LTP::Environment->new() };
    has test => sub { OpenQA::Parser::Result::LTP::SubTest->new() };
    has [qw(status test_fqn)];
}

# Additional data structure - they get mapped automatically
{
    package OpenQA::Parser::Result::LTP::SubTest;
    use Mojo::Base 'OpenQA::Parser::Result::Test';

    has [qw(log duration result)];
}

{
    package OpenQA::Parser::Result::LTP::Environment;
    use Mojo::Base 'OpenQA::Parser::Result';

    has [qw(gcc product revision kernel ltp_version harness libc arch)];
}

=head1 NAME

OpenQA::Parser::Format::LTP - LTP file parser

=head1 SYNOPSIS

    use OpenQA::Parser::Format::LTP;

    my $parser = OpenQA::Parser::Format::LTP->new()->load('file.json');

    # Alternative interface
    use OpenQA::Parser qw(parser p);

    my $parser = p('LTP')->include_result(1)->load('file.json');

    my $parser = parser( LTP => 'file.json' );

    my $result_collection = $parser->results();
    my $test_collection   = $parser->tests();
    my $output_collection = $parser->output();
    my $extra_collection  = $parser->extra();

    my $environment = $parser->extra()->first;  # Since LTP format v2

    my $arrayref = $extra_collection->to_array;

    $parser->results->remove(0);

    my $passed_results = $parser->results->search( result => qr/ok/ );
    my $size = $passed_results->size;

=head1 DESCRIPTION

OpenQA::Parser::Format::LTP is the parser for the ltp file format.
The parser is making use of the C<tests()>, C<results()>, C<output()> and C<extra()> collections.

With the attribute C<include_result()> set to true, it will include inside the
results the respective test that generated it (inside the C<test()> attribute).
See also L<OpenQA::Parser::Result::OpenQA>.

The C<extra()> collection was introduced in the format v2,
which can include the environment of the tests shared among the results.
After the parsing, depending on the processed file, it should contain one element,
which is the environment.

    my $parser = parser( LTP => 'file.json' );

    my $environment = $parser->extra()->first;

Results objects are of specific type, as they are including additional attributes that are
supported only by the format (thus not by openQA).

=head1 ATTRIBUTES

OpenQA::Parser::Format::LTP inherits all attributes from L<OpenQA::Parser::Format::JUnit>.

=head1 METHODS

OpenQA::Parser::Format::LTP inherits all methods from L<OpenQA::Parser::Format::JUnit>, it only overrides
C<parse()> to generate a tree of results.

=cut

1;
