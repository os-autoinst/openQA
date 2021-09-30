# Copyright 2017-2018 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Parser::Result::OpenQA;
use Mojo::Base 'OpenQA::Parser::Result';

# Basic class that holds the tests details and results as seen by openQA
# Used while parsing from format X to OpenQA test modules.
use OpenQA::Parser::Results;
use OpenQA::Parser::Result::OpenQA::Results;
use Mojo::File 'path';

has details => sub { [] };
has dents => 0;
has [qw(result name test)];

sub new { shift->SUPER::new(@_)->parsed_details }

# Adds _source => 'parser' to all the details of the result
sub parsed_details {
    my $self = shift;
    return $self->details([map { $_->{_source} = 'parser'; $_ } @{$self->details}]);
}

sub search_in_details {
    my ($self, $field, $re) = @_;
    my $results = OpenQA::Parser::Result::OpenQA::Results->new();
    $results->add($_) for grep { ($_->{$field} // '') =~ $re } @{$self->details};
    return $results;
}

# For internal use
sub to_openqa {
    my $self = shift;
    return {
        result => $self->result,
        dents => $self->dents,
        details => $self->details
    };
}

# For generating files that can be read by openQA
sub TO_JSON {
    my ($self, $test) = @_;

    my @test = $test ? (test => $self->test ? $self->test->TO_JSON : undef) : ();
    return {
        result => $self->result,
        dents => $self->dents,
        details => $self->details,
        @test
    };
}

# Override to get automatically the file name
sub write {
    my ($self, $name) = @_;
    my $path = path($name, 'result-' . $self->name . '.json');
    return $self->SUPER::write($path);
}

1;

=encoding utf-8

=head1 NAME

OpenQA::Parser::Result::OpenQA - OpenQA result class

=head1 SYNOPSIS

    use OpenQA::Parser::Result::OpenQA;

    my $result = OpenQA::Parser::Result::OpenQA->new( details => [ {text => ''}, ... ],
                                                      dents => 3,
                                                      result => 'ok' );

    my @details = @{ $result->details() };
    my $dents   = $result->dents();
    my $state   = $result->result();
    my $name    = $result->name();
    my $test    = $result->test();

    $result->details([qw(a b c), qw(b c d)]);
    $result->dents(4);
    $result->result('ok');
    $result->name('test_1');
    $result->test();

=head1 DESCRIPTION

OpenQA::Parser::Result::OpenQA it is representing an openQA result.
It may optionally include the test that generated it.
Elements of the parser tree that wish to map it's data with openQA needs to inherit this class.

=head1 ATTRIBUTES

OpenQA::Parser::Result::OpenQA inherits all attributes from L<OpenQA::Parser::Result>
and implements the following new ones: C<details()>, C<dents()>, C<result()>, C<name()> and C<test()>.
Respectively mapping the openQA test result fields.
Note: only C<details()>, C<dents()> and C<result()> are 'required' by openQA.
The other are optional and used to ease out results parsing/reading e.g. test can contain
the test that generated the result in some format implementations.

=head1 METHODS

OpenQA::Parser::Result::OpenQA inherits all methods from L<OpenQA::Parser::Result>
and implements the following new ones:

=head2 search_in_details()

    use OpenQA::Parser::Result::OpenQA;

    my $result = OpenQA::Parser::Result::OpenQA->new( details => [ {text => 'foo'}, ... ],
                                                      dents => 3,
                                                      result => 'ok' );
    my $results = $result->search_in_details('text' => qr/foo/);
    my $text = $results->first->{text};

Returns a L<OpenQA::Parser::Result::OpenQA::Results> collection containing the details results of the search.
It assumes that C<details()> of the result object is a arrayref of hashrefs.

=head2 write()

    use OpenQA::Parser::Result::OpenQA;

    my $result = OpenQA::Parser::Result::OpenQA->new( details => [ {text => 'foo'}, ... ],
                                                      dents => 3,
                                                      result => 'ok' );
    $result->write('directory/');

It will encode and write the result file as JSON in the supplied directory. The name of the
file is extracted from the object name attribute, following openQA expectations.

=head2 to_openqa()

    use OpenQA::Parser::Result::OpenQA;

    my $result = OpenQA::Parser::Result::OpenQA->new( details => [ {text => 'foo'}, ... ],
                                          dents => 3,
                                          result => 'ok' );
    my $info = $result->to_openqa;
    # { details => [], dents=> 3, result=>'ok' }

It will return a hashref which contains as elements the only one strictly required by openQA
to parse the result.

=cut
