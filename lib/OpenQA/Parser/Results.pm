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
    my $results = OpenQA::Parser::Results->new();
    $self->each(sub { $results->add($_) if $_->$field =~ $re });
    $results;
}

sub new {
    my ($class, @args) = @_;

    OpenQA::Parser::_restore_tree_section(\@args);

    return $class->SUPER::new(map { _restore_el($_); $_ } @args);
}

sub to_json   { encode_json shift()->to_array }
sub from_json { __PACKAGE__->new(@{decode_json $_[1]}) }

*_restore_el = \&OpenQA::Parser::_restore_el;

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
sub deserialize { __PACKAGE__->new(@{Storable::thaw($_[1])}) }

sub reset { @{$_[0]} = () }

1;
