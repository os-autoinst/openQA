# Copyright 2015-2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Parser::Result::OpenQA::Results;
use Mojo::Base 'OpenQA::Parser::Results';

use Scalar::Util 'blessed';

# Returns a new flattened OpenQA::Parser::Results which is a cumulative result of
# the other collections inside it
sub search_in_details {
    my ($self, $field, $re) = @_;
    return $self->new(
        map { $_->search_in_details($field, $re) }
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
