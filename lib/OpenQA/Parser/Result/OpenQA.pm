# Copyright (C) 2017-2018 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::Parser::Result::OpenQA;
# Basic class that holds the tests details and results as seen by openQA
# Used while parsing from format X to OpenQA test modules.

use Mojo::Base 'OpenQA::Parser::Result';
use OpenQA::Parser::Results;
use Mojo::File 'path';

has details => sub { [] };
has dents => 0;
has [qw(result name test)];

sub search_in_details {
    my ($self, $field, $re) = @_;
    my $results = OpenQA::Parser::Result::OpenQA::Results->new();
    $results->add($_) for grep { $_->{$field} =~ $re } @{$self->details};
    $results;
}

# For internal use
sub to_openqa {
    return {
        result  => $_[0]->result(),
        dents   => $_[0]->dents(),
        details => $_[0]->details()};
}

# For generating files that can be read by openQA
sub TO_JSON {
    return {
        result  => $_[0]->result(),
        dents   => $_[0]->dents(),
        details => $_[0]->details(),
        (test => $_[0]->test ? $_[0]->test->TO_JSON : undef) x !!($_[1])};
}

# Override to get automatically the file name
sub write { $_[0]->SUPER::write(path($_[1], join('.', join('-', 'result', $_[0]->name), 'json'))) }

{
    package OpenQA::Parser::Result::OpenQA::Results;
    # Basic class that holds the tests details and results as seen by openQA
    # Used while parsing from format X to OpenQA test modules.

    use Mojo::Base 'OpenQA::Parser::Results';
    use Scalar::Util 'blessed';

    # Returns a new flattened OpenQA::Parser::Results which is a cumulative result of
    # the other collections inside it
    sub search_in_details {
        my ($self, $field, $re) = @_;
        __PACKAGE__->new(
            map { $_->search_in_details($field, $re) }
            grep { blessed($_) && $_->isa("OpenQA::Parser::Result") } @{$self})->flatten;
    }

    sub search {
        my ($self, $field, $re) = @_;
        my $results = $self->new();
        $self->each(sub { $results->add($_) if $_->{$field} =~ $re });
        $results;
    }
}

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

1;
