# Copyright (C) 2014 SUSE Linux Products GmbH
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package OpenQA::Schema::ResultSet::Jobs;
use strict;
use base qw/DBIx::Class::ResultSet/;

=head2 latest_build

=over

=item Arguments: hash with settings values to filter by

=item Return value: value of BUILD for the latests job matching the arguments

=back

Returns the value of the BUILD setting of the latest (most recently created)
job that matchs the settings provided as argument. Useful to find the
latest build for a given pair of distri and version.

=cut
sub latest_build {
    my $self = shift;
    my %args = @_;
    my @conds;
    my %attrs;
    my $rsource = $self->result_source;
    my $schema = $rsource->schema;

    my $groupid = delete $args{groupid};
    if (defined $groupid) {
        push(@conds, {'me.group_id' => $groupid } );
    }

    $attrs{join} = 'settings';
    $attrs{rows} = 1;
    $attrs{order_by} = { -desc => 'me.id' }; # More reliable for tests than t_created
    $attrs{columns} = [ { value => 'settings.value'} ];
    push(@conds, {'settings.key' => {'=' => 'BUILD'}});

    while (my($k, $v) = each %args) {
        my $subquery = $schema->resultset("JobSettings")->search(
            {
                key => uc($k),
                value => $v
            }
        );
        push(@conds, { 'me.id' => { -in => $subquery->get_column('job_id')->as_query }});
    }

    my $rs = $self->search({-and => \@conds}, \%attrs);
    return $rs->get_column('value')->first;
}

1;
# vim: set sw=4 et:
