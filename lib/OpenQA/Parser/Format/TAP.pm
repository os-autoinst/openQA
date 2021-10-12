# Copyright 2018 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Parser::Format::TAP;
use Mojo::Base 'OpenQA::Parser::Format::Base';

# Translates to TAP -> openQA internal
use Carp qw(croak confess);
use OpenQA::Parser::Result::OpenQA;
use TAP::Parser;

has [qw(test steps)];

sub parse {
    my ($self, $TAP) = @_;
    confess "No TAP given/loaded" unless $TAP;
    my $tap = TAP::Parser->new({tap => $TAP});
    confess "Failed " . $tap->parse_errors if $tap->parse_errors;
    my $test = {
        flags => {},
        category => "TAP",
        name => 'Extra test from TAP',
    };
    my $details;

    $self->steps(
        OpenQA::Parser::Result->new(
            {
                details => [],
                dents => 0,
                result => 'passed'
            }));
    my $m = 0;
    while (my $res = $tap->next) {
        my $result = $res;
        if ($result->raw =~ m/^(.*\.(?:[a-zA-Z0-9]+)) \.{2}/g) {
            # most cases, the output of a prove run will contain
            # "/t/$filename.tap .." as name of the file
            # use this to get the filename
            $test->{name} = $1;
            $test->{name} =~ s/[\/.]/_/g;
            $self->test(OpenQA::Parser::Result->new($test));
            $self->_add_test($self->test);
            next;
        }
        else {
            confess "A valid TAP starts with filename.tap, and got: '@{[$result->raw]}'" unless $self->test;
        }

        # For the time being only load known types
        # Tests are supported and comments too
        # stick for now to only test results.
        next if $result->type eq 'plan';    # Skip plans for now
        next if $result->type ne 'test';

        my $t_filename = "TAP-@{[$test->{name}]}-$m.txt";
        my $t_description = $result->description;
        $t_description =~ s/^- //;
        $details = {
            text => $t_filename,
            title => $t_description,
            result => ($result->is_actual_ok) ? 'ok' : 'fail',
        };
        $self->steps->{result} = 'fail' if !$result->is_actual_ok;    #Mark the suite as failed if it was not ok.

        # Ensure that text files are going to be written
        # With the content that is relevant
        my $data = {%$result, %$details};
        push @{$self->steps->{details}}, $data;
        $self->_add_output(
            {
                file => $t_filename,
                content => $res->raw
            });
        ++$m;
    }
    $self->steps->{name} = $self->tests->first->{name};
    $self->steps->{test} = $self->tests->first;
    $self->generated_tests_results->add(OpenQA::Parser::Result::OpenQA->new($self->steps));
}

=encoding utf-8

=head1 NAME

OpenQA::Parser::Format::TAP - TAP file parser

=head1 SYNOPSIS

    use OpenQA::Parser::Format::TAP;

    my $parser = OpenQA::Parser::Format::TAP->new()->load('test.tap');

    # Alternative interface
    use OpenQA::Parser qw(parser p);

    my $parser = p( TAP => 'test.tap' );

    my $result_collection = $parser->results();
    my $test_collection   = $parser->tests();
    my $output_collection = $parser->output();

    my $arrayref = $result_collection->to_array;

    $parser->results->remove(0);

    my $passed_results = $parser->results->search( result => qr/ok/ );
    my $size = $passed_results->size;

=head1 DESCRIPTION

OpenQA::Parser::Format::TAP is the parser for Test Anything Protocol format.
The parser is making use of the C<tests()>, C<results()> and C<output()> collections.

The parser will store the information from each test step along with the test step details.

=head1 ATTRIBUTES

OpenQA::Parser::Format::TAP inherits all attributes from L<OpenQA::Parser::Format::Base> and implements
the following attributes.

=head2 test

Holds an instance of C<OpenQA::Parser::Result> containing the details of the current test being parsed.

=head2 steps

Contains a list of the test lines provided by the TAP::Parser it is then combined and added as test results
via C<OpenQA::Parser::Format::Base::generated_tests_results>.

=head1 METHODS

OpenQA::Parser::Format::TAP inherits all methods from L<OpenQA::Parser::Format::Base>, it only overrides
C<parse()> to generate a simple tree of results.

=head1 CAVEATS

TAP parser will treat each file as a test case, with N steps, as such it expects C<filename.t ..>
or C<filename.tap ..> as the first line in the file to be parsed, further parsing will not be done
until this requirement is met.

=over 4

=item SUBTESTS

Currently TAP::Harness does not properly parse subtests, therefore they are not supported by this TAP parser,

=item NOT SUPPORTED ELEMENTS

As this is a simple implementation elements from C<Comments>, C<Plans>, C<Directives> and C<Bails> are not supported, therefore
are discarded by the parser.

=back

=cut

1;
