# Copyright 2016-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

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

    my @conds;
    # Search into the following job_settings
    for my $setting (keys %$args) {
        next unless $args->{$setting};
        # for dynamic self joins we need to be creative ;(
        my $tname = 'me';
        my $setting_value = ($args->{$setting} =~ /^:\w+:/) ? {'like', "$&%"} : $args->{$setting};
        push(
            @conds,
            {
                "$tname.key" => $setting,
                "$tname.value" => $setting_value
            });
    }
    return $self->search({-and => \@conds});
}

1;
