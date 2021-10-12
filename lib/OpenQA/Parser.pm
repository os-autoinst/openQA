# Copyright 2017-2018 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Parser;
use Mojo::Base -base;

use Carp qw(croak confess);
use Mojo::File 'path';
use Mojo::Collection;
use Mojo::Loader 'load_class';
use Mojo::JSON qw(encode_json decode_json);
use OpenQA::Parser::Result::Test;
use OpenQA::Parser::Result::Output;
use OpenQA::Parser::Result;
use OpenQA::Parser::Results;
use Storable;
use Scalar::Util qw(blessed reftype);
use constant DATA_FIELD => '__data__';
use constant TYPE_FIELD => '__type__';
use OpenQA::Utils 'walker';
use Exporter 'import';

our @EXPORT_OK = qw(parser p);

has include_content => 0;
has 'content';

# parser( Format => 'file.json')
# or parser( 'Format' )
sub parser {
    @_ > 1 && ref $_[0] ne 'HASH' ? _build_parser(shift(@_))->load(shift(@_)) : _build_parser(shift(@_));
}

sub _build_parser {
    my $wanted_parser = shift // 'Base';
    my $parser_name = "OpenQA::Parser::Format::${wanted_parser}";
    my @args = @_;
    my $p_instance;
    {
        if (my $e = load_class $parser_name) {
            croak ref $e ? "Exception: $e" : 'Parser not found!';
        }
        no strict 'refs';    ## no critic
        eval { $p_instance = $parser_name->new(@args); };
        croak "Invalid parser supplied: $@" if $@;
    }
    $p_instance;
}

sub load {
    my ($self, $file) = @_;
    croak "You need to specify a file" if !$file;
    my $file_content = $self->_read_file($file);
    confess "Failed reading file $file" if !$file_content;
    $self->content($file_content) if $self->include_content;
    $self->parse($file_content);
    $self;
}

sub parse { croak 'parse() not implemented by base class' }

sub _read_file { path($_[1])->slurp() }

sub reset {
    my $self = shift;

    do {
        do { $self->{$_}->reset(); next } if blessed $self->{$_} && $self->{$_}->can('reset');
        $self->{$_} = undef;
      }
      for (sort keys %{$self});
}

# Serialization - tree building functions
sub gen_tree_el {
    my $el = shift;
    return {DATA_FIELD() => $el} unless blessed $el;

    my $el_ref;
    if ($el->isa('OpenQA::Parser')) {
        $el_ref = $el;
    }
    elsif ($el->can("gen_tree_el")) {
        return $el->gen_tree_el;
    }
    elsif ($el->can("to_hash")) {
        $el_ref = $el->to_hash;
    }
    elsif ($el->can("to_array")) {
        $el_ref = $el->to_array;
    }
    elsif (reftype $el eq 'ARRAY') {
        warn "Serialization is officially supported only if object can be turned into an array with ->to_array()";
        $el_ref = [@{$el}];
    }
    elsif (reftype $el eq 'HASH') {
        warn "Serialization is officially supported only if object can be hashified with ->to_hash()";
        $el_ref = {%{$el}};
    }
    else {
        warn "Data type with format not supported for serialization";
        $el_ref = $el;
    }

    return {DATA_FIELD() => $el_ref, TYPE_FIELD() => ref $el};
}

sub _build_tree {
    my $self = shift;

    my $tree;
    my @coll = sort keys %{$self};

    foreach my $collection (@coll) {
        if (blessed $self->{$collection} && $self->{$collection}->can('each')) {
            $self->$collection->each(
                sub {
                    push(@{$tree->{$collection}}, gen_tree_el($_));
                });
        }
        else {
            $tree->{$collection} = gen_tree_el($self->{$collection});
        }
    }
    return $tree;
}

sub restore_el {
    my $obj = shift;
    return $obj if blessed $obj;
    return $obj if ref $obj eq 'ARRAY';
    return $obj unless ref $obj eq 'HASH' && exists $obj->{OpenQA::Parser::DATA_FIELD()};
    return $obj->{OpenQA::Parser::DATA_FIELD()} unless exists $obj->{OpenQA::Parser::TYPE_FIELD()};

    my $type = $obj->{OpenQA::Parser::TYPE_FIELD()};
    my $data = $obj->{OpenQA::Parser::DATA_FIELD()};

    {
        no strict 'refs';    ## no critic
        return $type->can('new') ? $type->new(ref $data eq 'ARRAY' ? @{$data} : $data) : $data;
    };
}

sub restore_tree_section {
    my $ref = shift;
    eval {
        walker $ref => sub {
            my ($key, $value, $keys) = @_;
            my $hash = $ref;
            for (my $i = 0; $i < scalar @$keys - 1; $i++) {
                my ($type, $kk) = @{$keys->[$i]};
                $hash = $hash->{$kk} if $type eq 'HASH';
                $hash = $hash->[$kk] if $type eq 'ARRAY';
            }


            $hash->{$key} = restore_el($value) if reftype $hash eq 'HASH';
            $hash->[$key] = restore_el($value) if reftype $hash eq 'ARRAY';
        };
    };
    confess $@ if $@;
}

sub _load_tree {
    my $self = shift;

    my $tree = shift;
    my @coll = sort keys %{$tree};

    {
        no strict 'refs';    ## no critic
        local $@;
        eval {
            foreach my $collection (@coll) {
                if (ref $tree->{$collection} eq 'ARRAY') {
                    $self->$collection->add(restore_el($_)) for @{$tree->{$collection}};
                }
                else {
                    $self->{$collection} = restore_el($tree->{$collection});
                }
            }
        };
        confess "Failed parsing tree: $@" if $@;
    }

    return $self;
}

sub serialize { Storable::freeze(shift->_build_tree) }
sub deserialize { shift->_load_tree(Storable::thaw(shift)) }

sub to_json { encode_json shift->_build_tree }
sub from_json { shift->_load_tree(decode_json shift) }

sub save { my $s = shift; path(@_)->spurt($s->serialize); $s }
sub save_to_json { my $s = shift; path(@_)->spurt($s->to_json); $s }
sub from_file { shift->new()->deserialize(path(pop)->slurp()) }
sub from_json_file { shift->new()->from_json(path(pop)->slurp()) }

*p = \&parser;

=encoding utf-8

=head1 NAME

OpenQA::Parser - Parser for external tests results formats and serializer

=head1 SYNOPSIS

    use OpenQA::Parser::Format::XUnit;

    my $parser = OpenQA::Parser::Format::XUnit->new()->load('file.xml');

    # Alternative interface
    use OpenQA::Parser qw(parser p);

    my $parser = p('Base'); # Generate empty object

    my $parser = parser(XUnit => 'my_result.xml');

=head1 DESCRIPTION

OpenQA::Parser is the parser base object. Specific file format to be parsed have their own
parser Class that must inherit this one.

=head1 ATTRIBUTES

Implements the following attributes:

=head2 include_content

    use OpenQA::Parser 'parser';
    my $parser = parser('LTP')->include_content(1);

    $parser->load('file.json');
    # ....

    my $content = $parser->content;

Tells the parser to keep the original content of the parsed file.
It can be accessed later with C<content()>.

=head2 content()

    use OpenQA::Parser 'parser';
    my $parser = parser('LTP')->include_content(1);

    $parser->load('file.json');
    # ....

    my $content = $parser->content;

It returns the file parsed original content.

=head1 METHODS

L<OpenQA::Parser> inherits all methods from L<Mojo::Base> and implements
the following new ones:

=head2 load()

    use OpenQA::Parser qw(parser);
    my $p = parser('LTP')->load('file.json');

    use OpenQA::Parser qw(parser);
    my $p = parser( LTP => 'file.json' ); # ->load() is implied

    use OpenQA::Parser::Format::Dummy
    my $p = OpenQA::Parser::Format::Dummy->new()->load('file.json');

Load and parse a file.

=head2 parse()

    use OpenQA::Parser qw(parser);

    my $p = parser('LTP')->parse($json_content);

    use OpenQA::Parser::Format::LTP;
    my $p = OpenQA::Parser::Format::LTP->new()->parse('file.json');

Parse a string and decode it's content based on the format.
It returns the Parser object.

=head2 reset()

    use OpenQA::Parser qw(parser);

    my $p = parser('LTP')->parse($json_content);

    $p->reset();

Resets the parser state. All collections and the data tree is entirely wiped out.

=head2 serialize()

    use OpenQA::Parser qw(parser);

    my $p = parser('LTP')->parse($json_content);

    my $serialized_data = $p->serialize();

    my $p2 = parser('LTP')->deserialize($serialized_data);

Serialize the parser contents using L<Storable>. If the same content is given back
to C<deserialize()> it will regenerate the original content ( objects will be re-initialized ).

=head2 deserialize()

    use OpenQA::Parser qw(parser);

    my $parser = parser('Base')->deserialize($serialized_data);

Restore the parser tree and objects with the data provided. It expects a storable data blob.

=head2 save()

    use OpenQA::Parser qw(parser);

    my $parser = parser(LTP => 'file.json')->save('serialized.storable');

Save the L<Storable> serialization of the parser tree directly to file.


=head2 from_file()

    use OpenQA::Parser qw(parser);

    my $parser = parser('LTP')->from_file('serialized.storable');

Restore the L<Storable> serialization of the parser tree from file.
It returns the Parser object with the original data.

=head2 to_json()

    use OpenQA::Parser qw(parser);

    my $p = parser('LTP')->parse($json_content);

    my $json_encoded_data = $p->to_json();

    my $p2 = parser('LTP')->from_json($json_encoded_data);

Serialize the parser contents using JSON instead of L<Storable>. If the same content is given back
to C<from_json()> it will regenerate the original content ( objects will be re-initialized ).

=head2 from_json()

    use OpenQA::Parser qw(parser);

    my $parser = parser('Base')->from_json($json_encoded_data);

Restore the parser tree and objects with the data provided.
It expects a JSON structure representing the parser tree.
It returns the Parser object with the original data.

=head2 save_to_json()

    use OpenQA::Parser qw(parser);

    parser(LTP => 'file.json')->save_to_json('serialized.json');

Save the JSON serialization of the parser tree directly to file.


=head2 from_json()

    use OpenQA::Parser qw(parser);

    my $parser = parser('LTP')->from_json('serialized.json');

Restore the JSON serialization of the parser tree from file.
It returns the Parser object with the original data.

=cut

1;
