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
    my $schema  = $rsource->schema;

    my $groupid = delete $args{groupid};
    if (defined $groupid) {
        push(@conds, {'me.group_id' => $groupid});
    }

    $attrs{join}     = 'settings';
    $attrs{rows}     = 1;
    $attrs{order_by} = {-desc => 'me.id'};              # More reliable for tests than t_created
    $attrs{columns}  = [{value => 'settings.value'}];
    push(@conds, {'settings.key' => {'=' => 'BUILD'}});

    while (my ($k, $v) = each %args) {
        my $subquery = $schema->resultset("JobSettings")->search(
            {
                key   => uc($k),
                value => $v
            });
        push(@conds, {'me.id' => {-in => $subquery->get_column('job_id')->as_query}});
    }

    my $rs = $self->search({-and => \@conds}, \%attrs);
    return $rs->get_column('value')->first;
}

=head2 latest_jobs

=over

=item Return value: array of only the most recent jobs in the resultset

=back

De-duplicates the jobs in the result set. Jobs are considered 'duplicates'
if they are for the same DISTRI, VERSION, BUILD, TEST, FLAVOR, ARCH and
MACHINE. For each set of dupes, only the latest job found is included in
the return array.

=cut
sub latest_jobs {
    my $self = shift;
    my @jobs = $self->search(undef, {order_by => ['me.id DESC']});
    my @latest;
    my %seen;
    foreach my $job (@jobs) {
        my $settings = $job->settings_hash;
        my $distri   = $settings->{DISTRI};
        my $version  = $settings->{VERSION};
        my $build    = $settings->{BUILD};
        my $test     = $settings->{TEST};
        my $flavor   = $settings->{FLAVOR} || 'sweet';
        my $arch     = $settings->{ARCH} || 'noarch';
        my $machine  = $settings->{MACHINE} || 'nomachine';
        my $key      = "$distri-$version-$build-$test-$flavor-$arch-$machine";
        next if $seen{$key}++;
        push(@latest, $job);
    }
    return @latest;
}
1;
# vim: set sw=4 et:
