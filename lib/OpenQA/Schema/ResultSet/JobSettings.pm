# Copyright (C) 2016 SUSE LLC
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

package OpenQA::Schema::ResultSet::JobSettings;

use strict;
use warnings;

use base 'DBIx::Class::ResultSet';

=head2 query_for_settings

=over

=item Return value: ResultSet (to be used as subquery)

=back

Given a perl hash, will create a ResultSet of job_settings


=cut
sub query_for_settings {
    my ($self, $args) = @_;

    my @joins;
    my @conds;
    # Search into the following job_settings
    for my $setting (keys %$args) {
        if ($args->{$setting}) {
            # for dynamic self joins we need to be creative ;(
            my $tname = 'me';
            if (@conds) {
                $tname = "siblings";
                if (@joins) {
                    $tname = "siblings_" . (int(@joins) + 1);
                }
                push(@joins, 'siblings');
            }
            my $setting_value = ($args->{$setting} =~ /^:\w+:/) ? {'like', "$&%"} : $args->{$setting};
            push(
                @conds,
                {
                    "$tname.key"   => $setting,
                    "$tname.value" => $setting_value
                });
        }
    }
    return $self->search({-and => \@conds}, {join => \@joins});
}

1;
