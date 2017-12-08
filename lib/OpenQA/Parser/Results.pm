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
use Mojo::Base 'Mojo::Collection';
use Scalar::Util 'blessed';
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

1;
