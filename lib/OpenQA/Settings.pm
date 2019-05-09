# Copyright (C) 2019 SUSE LLC
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

package OpenQA::Settings;

use warnings;
use strict;

sub new {
    my ($class, %args) = @_;

    my $self = {%args};
    bless $self, $class;
    return $self;
}

# replace %NAME% in values with $self->{NAME}
sub expand_placeholders {
    my ($self) = @_;

    for my $value (values %{$self}) {
        if (defined $value) {
            $value =~ s/(%\w+%)/$self->_replace($1)/eig;
        }
    }
    return $self;
}

sub _replace {
    my ($self, $param) = @_;

    my $key = $param;
    $key =~ s/%//g;

    if (defined $self->{$key}) {
        return $self->{$key};
    }
    return $param;
}

1;
