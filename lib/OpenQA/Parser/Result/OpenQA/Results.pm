# Copyright 2015-2019 SUSE LLC
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

package OpenQA::Parser::Result::OpenQA::Results;
use Mojo::Base 'OpenQA::Parser::Results';

use Scalar::Util 'blessed';

# Returns a new flattened OpenQA::Parser::Results which is a cumulative result of
# the other collections inside it
sub search_in_details {
    my ($self, $field, $re) = @_;
    return $self->new(
        map  { $_->search_in_details($field, $re) }
        grep { blessed($_) && $_->isa('OpenQA::Parser::Result') } @$self
    )->flatten;
}

sub search {
    my ($self, $field, $re) = @_;
    my $results = $self->new;
    $self->each(sub { $results->add($_) if $_->{$field} =~ $re });
    return $results;
}

1;

=encoding utf8

=head1 NAME

OpenQA::Parser::Result::OpenQA::Results - Results class

=head1 SYNOPSIS

    use OpenQA::Parser::Result::OpenQA::Results;

=head1 DESCRIPTION

L<OpenQA::Parser::Result::OpenQA::Results> is a class that holds the test
details and results as seen by openQA. It is used while parsing from format X to
OpenQA test modules.

=cut
