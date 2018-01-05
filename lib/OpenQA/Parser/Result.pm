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

package OpenQA::Parser::Result;
# Base class that holds the test result
# Used while parsing from format X to Whatever

use Mojo::Base -base;
use OpenQA::Parser::Results;
use OpenQA::Parser;

use Mojo::JSON qw(decode_json encode_json);
use Carp 'croak';
use Mojo::File 'path';
use Scalar::Util qw(blessed reftype);

sub new {
    return shift->SUPER::new(@_) unless @_ > 1 && reftype $_[1] && reftype $_[1] eq 'HASH' && !blessed $_[1];

    my ($class, @args) = @_;
    OpenQA::Parser::_restore_tree_section($args[0]);
    $class->SUPER::new(@args);
}

*_restore_el = \&OpenQA::Parser::_restore_el;

sub get { shift->{shift()} }

sub to_json   { encode_json shift->_gen_tree_el }
sub from_json { __PACKAGE__->new(_restore_el(decode_json $_[1])) }
sub to_hash {
    my $self = shift;
    return {
        map {
                $_ => blessed $self->{$_} && $self->{$_}->can("to_hash") ? $self->{$_}->to_hash
              : blessed $self->{$_} && $self->{$_}->can("to_array") ? $self->{$_}->to_array
              : $self->{$_}
          }
          sort keys %{$self}};
}

sub to_el {
    my $self = shift;

    return {
        map { $_ => blessed $self->{$_} && $self->{$_}->can("_gen_tree_el") ? $self->{$_}->_gen_tree_el : $self->{$_} }
        sort keys %{$self}};
}

sub _gen_tree_el {
    my $el = shift;
    return {OpenQA::Parser::DATA_FIELD() => $el->to_el, OpenQA::Parser::TYPE_FIELD() => ref $el};
}

sub write {
    my ($self, $dir) = @_;
    croak 'OpenQA::Parser::Result write() requires a name field' unless $self->can('name');
    path($dir, join('.', join('-', 'result', $self->name), 'json'))->spurt(encode_json($self));
}

*write_json = \&write;

1;
