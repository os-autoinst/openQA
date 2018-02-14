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

package OpenQA::Parser::Results;
# Generic result class.

use Mojo::Base 'Mojo::Collection';
use Scalar::Util 'blessed';
use OpenQA::Parser;
use Mojo::JSON qw(encode_json decode_json);
use Storable;

sub add {
    my $self = shift;
    push @{$self}, @_;
    $self;
}

sub get    { @{$_[0]}[$_[1]] }
sub remove { delete @{$_[0]}[$_[1]] }

sub new {
    my ($class, @args) = @_;

    OpenQA::Parser::_restore_tree_section(\@args);

    return $class->SUPER::new(map { _restore_el($_); $_ } @args);
}

sub to_json   { encode_json shift() }                      # Mojo will call TO_JSON
sub from_json { __PACKAGE__->new(@{decode_json $_[1]}) }

sub to_array {
    [map { blessed $_ && $_->can("to_hash") ? $_->to_hash : blessed $_ && $_->can("to_array") ? $_->to_array : $_ }
          @{shift()}];
}

sub to_el {
    [map { blessed $_ && $_->can("_gen_tree_el") ? $_->_gen_tree_el : $_ } @{shift()}];
}

sub _gen_tree_el {
    my $self = shift;
    return {OpenQA::Parser::DATA_FIELD() => $self->to_el, OpenQA::Parser::TYPE_FIELD() => ref $self};
}

sub serialize   { Storable::freeze($_[0]) }
sub deserialize { shift->new(@{Storable::thaw(shift)}) }

sub reset { @{$_[0]} = () }

*_restore_el = \&OpenQA::Parser::_restore_el;
*TO_JSON     = \&to_array;


=encoding utf-8

=head1 NAME

OpenQA::Parser::Results - Baseclass of parser collections

=head1 SYNOPSIS

    use OpenQA::Parser::Results;

    my $result = OpenQA::Parser::Results->new(qw(a b c));

    $result->add(OpenQA::Parser::Results->new(OpenQA::Parser::Result->new));
    $result->add('a');
    $result->add('b');
    $result->add('c');

    $results->remove(0);
    $results->get(1);
    $results->first();
    $results->last();
    $results->each( sub { ... } ); # See also Mojo::Collection's SYNOPSIS

=head1 DESCRIPTION

OpenQA::Parser::Results is the base object representing a collection of results.
Elements of the parser tree that represent an ARRAY needs to inherit this class.

=head1 METHODS

OpenQA::Parser::Result inherits all methods from L<Mojo::Collection>
and implements the following new ones:

=head2 get()

    use OpenQA::Parser::Results;

    my $results = OpenQA::Parser::Results->new(qw(a b c));
    my $first = $results->get(0);

Returns the element of the array at the index supplied.

=head2 add()

    use OpenQA::Parser::Results;

    my $results = OpenQA::Parser::Results->new(qw(a b c));
    $results->add('d');

Adds an element to the array.

=head2 remove()

    use OpenQA::Parser::Results;

    my $results = OpenQA::Parser::Results->new(qw(a b c));
    $results->remove(0);

Removes the element of the array at the index supplied.

=head2 reset()

    use OpenQA::Parser::Results;

    my $results = OpenQA::Parser::Results->new(qw(a b c));
    $results->reset;

Wipes the content of the array.

=head2 to_json()

    use OpenQA::Parser::Results;

    my $results = OpenQA::Parser::Result->new(qw(a b c));
    my $json = $results->to_json();

It will encode and return a string that is the JSON representation of the collection.

=head2 from_json()

    use OpenQA::Parser::Results;

    my $results = OpenQA::Parser::Results->new()->from_json($json_data);

It will restore the result and return a new object representing it.

=head2 to_array()

    use OpenQA::Parser::Results;

    my $results = OpenQA::Parser::Results->new(qw(a b c));
    my $arrayref = $results->to_array();

Turn collection into array reference.

=head2 to_el()

    use OpenQA::Parser::Results;

    my $results = OpenQA::Parser::Results->new(qw(a b c));
    my $el = $results->to_el();

It will encode the result and return a parser tree leaf representation.

=head2 serialize()

    use OpenQA::Parser::Results;

    my $p = OpenQA::Parser::Results->new(qw(a b c));

    my $serialized_data = $results->serialize();

    my $original_data = OpenQA::Parser::Results->new->deserialize($serialized_data);

Serialize the parser contents using L<Storable>.

=head2 deserialize()

    use OpenQA::Parser::Results;

    my $original_data = OpenQA::Parser::Results->new->deserialize($serialized_data);

Restore the object with the data provided. It expects a storable data blob.

=head2 TO_JSON

    my $array = $result->TO_JSON;

Alias for L</"to_array">.

=cut

1;
