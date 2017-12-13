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
use Mojo::JSON qw(decode_json encode_json);
use Carp 'croak';
use Mojo::File 'path';
use OpenQA::Utils 'hihwalker';

sub new {
    return shift->SUPER::new(@_) unless ref $_[1] eq 'HASH';

    my ($class, @args) = @_;

    hihwalker $args[0] => sub {
        my ($key, $value, $keys) = @_;

        my $hash = $args[0];
        for (my $i = 0; $i < scalar @$keys; $i++) {
            $hash = $hash->{$keys->[$i]} if $i < (scalar @$keys) - 1;
        }

        return unless $class->can($key);
        {
            no strict 'refs';    ## no critic
            my $ref = ref($class->new->$key());
            return unless $ref;
            $hash->{$key} = $ref->new($value) unless (grep(/$ref/, qw(HASH ARRAY)));
        }

    };

    $class->SUPER::new(@args);
}

sub to_json   { encode_json shift }
sub from_json { __PACKAGE__->new(decode_json $_[1]) }
sub to_hash {
    my $self = shift;
    return {map { $_ => $self->{$_} } sort keys %{$self}};
}

sub write {
    my ($self, $dir) = @_;
    croak 'OpenQA::Parser::Result write() requires a name field' unless $self->can('name');
    path($dir, join('.', join('-', 'result', $self->name), 'json'))->spurt(encode_json($self));
}

*write_json = \&write;

1;
