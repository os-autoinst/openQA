# Copyright (C) 2020 LLC
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

package OpenQA::Schema::ResultSet::Comments;

use strict;
use warnings;

use base 'DBIx::Class::ResultSet';

use OpenQA::App;
use OpenQA::Utils;

=over 4

=item compute_bugref_count()

Return a hashref of all bugs referenced by job comments with the number of references.

=back

=cut

sub compute_bugref_count {
    my ($self) = @_;

    my $comments = $self->search({-not => {job_id => undef}});
    my %bugrefs;
    for my $comment ($comments->all) {
        for my $bug (@{find_bugrefs($comment->text)}) {
            $bugrefs{$bug} += 1;
        }
    }
    return \%bugrefs;
}

1;
