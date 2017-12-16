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
use Scalar::Util 'blessed';

our @EXPORT_OK = qw(parser p);
use Exporter 'import';

use constant
  SERIALIZABLE_COLLECTIONS => qw(generated_tests_results generated_tests_output),
  qw(generated_tests generated_tests_extra);

has generated_tests => sub { OpenQA::Parser::Results->new };    #testsuites
has generated_tests_results =>
  sub { OpenQA::Parser::Results->new };    #testsuites results - when include_result is set it includes also the test.
has generated_tests_output => sub { OpenQA::Parser::Results->new };    #testcase results
has generated_tests_extra  => sub { OpenQA::Parser::Results->new };    # tests extra data.

*results = \&generated_tests_results;
*tests   = \&generated_tests;
*outputs = \&generated_tests_output;
*extra   = \&generated_tests_extra;
*p       = \&parser;


# parser("Format", "file")
# parser("LTP")->load("file")
# parser("Whatever")
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

sub _add_test   { shift->generated_tests->add(OpenQA::Parser::Result::Test->new(@_)) }
sub _add_result { shift->generated_tests_results->add(OpenQA::Parser::Result->new(@_)) }
sub _add_output { shift->generated_tests_output->add(OpenQA::Parser::Result::Output->new(@_)) }

sub _build_tree {
    my $self = shift;
    my $tree;
    foreach my $collection (SERIALIZABLE_COLLECTIONS) {
        $self->$collection->each(
            sub {
                my $to_hash;
                my @type = (type => ref $_);
                if (blessed $_ && $_->can("to_hash")) {
                    $to_hash = $_->to_hash;
                }
                elsif (blessed $_ && !$_->can("to_hash")) {
                    warn "Serialization is offically supported only if object can be hashified with ->to_hash()";
                    $to_hash = {%$_};
                }
                else {
                    $to_hash = $_;
                    @type    = ();
                }
                push(@{$tree->{$collection}}, {data => $to_hash, @type});
            });
    }
    return $tree;
}

sub _load_tree {
    my $self = shift;

    my $tree = shift;
    {
        no strict 'refs';    ## no critic
        local $@;
        eval {
            foreach my $collection (SERIALIZABLE_COLLECTIONS) {
                $self->$collection->add(
                    $_->{type} ? $_->{type}->new($_->{data}) : ref $_->{data} eq "ARRAY" ? @{$_->{data}} : $_->{data})
                  for @{$tree->{$collection}};
            }
        };
        die "Failed parsing tree: $@" if $@;
    }

    return $self;
}

sub serialize   { Storable::freeze(shift->_build_tree) }
sub deserialize { shift->_load_tree(Storable::thaw(shift)) }

sub to_json   { encode_json shift->_build_tree }
sub from_json { shift->_load_tree(decode_json shift) }

sub reset { my $self = shift; $self->$_->reset() for SERIALIZABLE_COLLECTIONS }


!!42;
