# Copyright (C) 2017 SUSE LLC
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


our @EXPORT_OK = qw(parser p);
use Exporter 'import';

has generated_tests => sub { OpenQA::Parser::Results->new };    #testsuites
has generated_tests_results =>
  sub { OpenQA::Parser::Results->new };    #testsuites results - when include_result is set it includes also the test.
has generated_tests_output => sub { OpenQA::Parser::Results->new };    #testcase results
has generated_tests_extra  => sub { OpenQA::Parser::Results->new };    # tests extra data.

has include_content => 0;
has 'content';

*results = \&generated_tests_results;
*tests   = \&generated_tests;
*outputs = \&generated_tests_output;
*extra   = \&generated_tests_extra;
*p       = \&parser;

# parser( Format => 'file.json')
# or parser( 'Format' )
sub parser {
    @_ > 1 && ref $_[0] ne 'HASH' ? _build_parser(shift(@_))->load(shift(@_)) : _build_parser(shift(@_));
}

sub _build_parser {
    my $wanted_parser = shift;
    croak 'You need to specify a parser - base class does not parse' if !$wanted_parser;
    my $parser_name = "OpenQA::Parser::Format::${wanted_parser}";
    my @args        = @_;
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

sub _write_all {
    my ($self, $res, $dir) = @_;
    path($dir)->make_path unless -d $dir;
    $self->$res->each(sub { $_->write($dir) });
    $self;
}

sub write_output {
    my ($self, $dir) = @_;
    croak "You need to specify a directory" unless $dir;
    $self->_write_all(generated_tests_output => $dir);
}

sub write_test_result {
    my ($self, $dir) = @_;
    croak "You need to specify a directory" unless $dir;
    $self->_write_all(generated_tests_results => $dir);
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

sub _add_test   { shift->generated_tests->add(OpenQA::Parser::Result::Test->new(@_)) }
sub _add_result { shift->generated_tests_results->add(OpenQA::Parser::Result->new(@_)) }
sub _add_output { shift->generated_tests_output->add(OpenQA::Parser::Result::Output->new(@_)) }

# Serialization - tree building functions
sub _gen_tree_el {
    my $el = shift;
    return {DATA_FIELD() => $el} unless blessed $el;

    my $el_ref;
    if ($el->can("_gen_tree_el")) {
        return $el->_gen_tree_el;
    }
    elsif ($el->can("to_hash")) {
        $el_ref = $el->to_hash;
    }
    elsif ($el->can("to_array")) {
        $el_ref = $el->to_array;
    }
    elsif (reftype $el eq 'ARRAY') {
        warn "Serialization is offically supported only if object can be turned into an array with ->to_array()";
        $el_ref = [@{$el}];
    }
    elsif (reftype $el eq 'HASH') {
        warn "Serialization is offically supported only if object can be hashified with ->to_hash()";
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
                    push(@{$tree->{$collection}}, _gen_tree_el($_));
                });
        }
        else {
            $tree->{$collection} = _gen_tree_el($self->{$collection});
        }
    }
    return $tree;
}

sub _restore_el {
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

sub _restore_tree_section {
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


            $hash->{$key} = _restore_el($value) if reftype $hash eq 'HASH';
            $hash->[$key] = _restore_el($value) if reftype $hash eq 'ARRAY';
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
                    $self->$collection->add(_restore_el($_)) for @{$tree->{$collection}};
                }
                else {
                    $self->{$collection} = _restore_el($tree->{$collection});
                }
            }
        };
        confess "Failed parsing tree: $@" if $@;
    }

    return $self;
}

sub serialize   { Storable::freeze(shift->_build_tree) }
sub deserialize { shift->_load_tree(Storable::thaw(shift)) }

sub to_json   { encode_json shift->_build_tree }
sub from_json { shift->_load_tree(decode_json shift) }

sub save         { my $s = shift; path(@_)->spurt($s->serialize); $s }
sub save_to_json { my $s = shift; path(@_)->spurt($s->to_json);   $s }
sub from_file    { __PACKAGE__->new()->deserialize(path(pop)->slurp()) }
sub from_json_file { __PACKAGE__->new()->from_json(path(pop)->slurp()) }

!!42;
