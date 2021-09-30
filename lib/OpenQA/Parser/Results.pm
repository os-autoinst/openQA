# Copyright 2017-2018 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Parser::Results;
use Mojo::Base 'Mojo::Collection';

# Generic result class.

use Scalar::Util 'blessed';
use OpenQA::Parser;
use Mojo::JSON qw(encode_json decode_json);
use Storable;

sub add {
    my ($self, @results) = @_;
    push @$self, @results;
    return $self;
}

sub get { @{$_[0]}[$_[1]] }
sub remove { delete @{$_[0]}[$_[1]] }

sub new {
    my ($class, @args) = @_;
    OpenQA::Parser::restore_tree_section(\@args);
    return $class->SUPER::new(map { OpenQA::Parser::restore_el($_); $_ } @args);
}

# Mojo will call TO_JSON
sub to_json { encode_json shift() }
sub from_json { shift->new(@{decode_json shift()}) }

sub to_array {
    my $self = shift;
    return [map { maybe_convert_to_hash_or_array($_) } @$self];
}

sub to_el {
    my $self = shift;
    return [map { maybe_convert_to_el($_) } @$self];
}

sub serialize { Storable::freeze(shift) }
sub deserialize { shift->new(@{Storable::thaw(shift)}) }

sub reset { @{$_[0]} = () }

sub TO_JSON { shift->to_array }

sub maybe_convert_to_el {
    my $value = shift;
    return $value->gen_tree_el if blessed $value && $value->can('gen_tree_el');
    return $value;
}

sub maybe_convert_to_hash_or_array {
    my $value = shift;
    return $value->to_hash if blessed $value && $value->can('to_hash');
    return $value->to_array if blessed $value && $value->can('to_array');
    return $value;
}

sub gen_tree_el {
    my $self = shift;
    return {OpenQA::Parser::DATA_FIELD() => $self->to_el, OpenQA::Parser::TYPE_FIELD() => ref $self};
}

1;

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
