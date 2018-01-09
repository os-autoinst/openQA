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

package OpenQA::Parser::Result::OpenQA;
# Basic class that holds the tests details and results as seen by openQA
# Used while parsing from format X to OpenQA test modules.

use Mojo::Base 'OpenQA::Parser::Result';
use OpenQA::Parser::Results;
use Mojo::File 'path';

has details => sub { [] };
has dents => 0;
has [qw(result name test)];

sub search_in_details {
    my ($self, $field, $re) = @_;
    my $results = OpenQA::Parser::Result::OpenQA::Results->new();
    $results->add($_) for grep { $_->{$field} =~ $re } @{$self->details};
    $results;
}

# For internal use
sub to_openqa {
    return {
        result  => $_[0]->result(),
        dents   => $_[0]->dents(),
        details => $_[0]->details()};
}

# For generating files that can be read by openQA
sub TO_JSON {
    return {
        result  => $_[0]->result(),
        dents   => $_[0]->dents(),
        details => $_[0]->details(),
        (test => $_[0]->test ? $_[0]->test->TO_JSON : undef) x !!($_[1])};
}

sub write { $_[0]->SUPER::write(path($_[1], join('.', join('-', 'result', $_[0]->name), 'json'))) }

{
    package OpenQA::Parser::Result::OpenQA::Results;
    # Basic class that holds the tests details and results as seen by openQA
    # Used while parsing from format X to OpenQA test modules.

    use Mojo::Base 'OpenQA::Parser::Results';
    use Scalar::Util 'blessed';

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
        my $results = $self->new();
        $self->each(sub { $results->add($_) if $_->{$field} =~ $re });
        $results;
    }
}

1;
