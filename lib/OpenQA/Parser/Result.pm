# Copyright 2017-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Parser::Result;
use Mojo::Base -base;

# Base class that holds the test result
# Used while parsing from format X to Whatever

use OpenQA::Parser::Results;
use OpenQA::Parser::Result::Node;
use OpenQA::Parser;
use Mojo::JSON qw(decode_json encode_json);
use Carp 'croak';
use Mojo::File 'path';
use Scalar::Util 'blessed';

sub new {
    my ($class, @args) = @_;
    OpenQA::Parser::restore_tree_section($args[0]) if @args && ref $args[0] eq 'HASH';
    return $class->SUPER::new(@args);
}

sub get { OpenQA::Parser::Result::Node->new(val => shift->{shift()}) }

sub to_json { encode_json shift() }
sub from_json { shift->new(decode_json shift()) }

sub to_hash {
    my $self = shift;
    return {map { $_ => OpenQA::Parser::Results::maybe_convert_to_hash_or_array($self->{$_}) } sort keys %$self};
}

sub to_el {
    my $self = shift;
    return {map { $_ => OpenQA::Parser::Results::maybe_convert_to_el($self->{$_}) } sort keys %$self};
}

sub write {
    my ($self, $path) = @_;
    croak __PACKAGE__ . ' write() requires a path' unless $path;
    my $json_data = $self->to_json;
    path($path)->spurt($json_data);
    return length $json_data;
}

sub write_json { shift->write(@_) }

sub serialize { Storable::freeze(shift->to_el) }
sub deserialize { shift()->new(OpenQA::Parser::restore_el(Storable::thaw(shift))) }

sub TO_JSON { shift->to_hash }

sub gen_tree_el {
    my $self = shift;
    return {OpenQA::Parser::DATA_FIELD() => $self->to_el, OpenQA::Parser::TYPE_FIELD() => ref $self};
}

1;

=encoding utf-8

=head1 NAME

OpenQA::Parser::Result - Baseclass of parser result

=head1 SYNOPSIS

    use OpenQA::Parser::Result;

    my $result = OpenQA::Parser::Result->new();

=head1 DESCRIPTION

OpenQA::Parser::Result is the base object representing a result.
Elements of the parser tree that represent a HASH needs to inherit this class.

=head1 METHODS

OpenQA::Parser::Result inherits all methods from L<Mojo::Base>
and implements the following new ones:

=head2 get()

    use OpenQA::Parser::Result;

    my $result = OpenQA::Parser::Result->new({ foo => { bar => 'baz' }});
    my $section = $result->get('foo');
    my $baz = $section->get('bar')->val();

Returns a L<OpenQA::Parser::Result::Node> object, which represent a subsection of the hash.
L<OpenQA::Parser::Result::Node> exposes only C<get()> and C<val()> methods and uses AUTOLOAD
features for sub-tree resolution.

C<get()> is used for getting further tree sub-sections,
it always returns a new L<OpenQA::Parser::Result::Node> which is a subportion of the result.
C<val()> returns the associated value.

=head2 write()

    use OpenQA::Parser::Result;

    my $result = OpenQA::Parser::Result->new({ foo => { bar => 'baz' }});
    $result->write('to_file.json');

It will encode and write the result as JSON.

=head2 TO_JSON

    my $hash = $result->TO_JSON;

Alias for L</"to_hash">.

=head2 to_json()

    use OpenQA::Parser::Result;

    my $result = OpenQA::Parser::Result->new({ foo => { bar => 'baz' }});
    my $json = $result->to_json();

It will encode and return a string that is the JSON representation of the result.

=head2 from_json()

    use OpenQA::Parser::Result;

    my $result = OpenQA::Parser::Result->new()->from_json($json_data);

It will restore the result and return a new result object representing it.

=head2 to_hash()

    use OpenQA::Parser::Result;

    my $result = OpenQA::Parser::Result->new({ foo => { bar => 'baz' }});
    my $json = $result->to_hash();

Turn object into hash reference.

=head2 to_el()

    use OpenQA::Parser::Result;

    my $result = OpenQA::Parser::Result->new({ foo => { bar => 'baz' }});
    my $el = $result->to_el();

It will encode the result and return a parser tree leaf representation.

=cut
