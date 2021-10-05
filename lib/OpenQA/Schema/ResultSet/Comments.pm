# Copyright 2020-2021 LLC
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

package OpenQA::Schema::ResultSet::Comments;

use strict;
use warnings;
use Mojo::Base -signatures;

use OpenQA::Utils qw(find_bugrefs);

use base 'DBIx::Class::ResultSet';

=over 4

=item referenced_bugs()

Return a hashref of all bugs referenced by job comments.

=back

=cut

sub referenced_bugs {
    my ($self) = @_;

    my $comments = $self->search({-not => {job_id => undef}});
    my %bugrefs  = map { $_ => 1 } map { @{find_bugrefs($_->text)} } $comments->all;
    return \%bugrefs;
}

=over 4

=item comment_data_for_jobs($jobs, $args)

Return a hashref with bugrefs, labels and the number of regular comments per job ID.

You can pass an additional argument C<bugdetails> if necessary:

    $self->comment_data_for_jobs($jobs, {bugdetails => 1});

if you need the Bug objects themselves.

=back

=cut

sub comment_data_for_jobs ($self, $jobs, $args = {}) {
    my @job_ids  = map { $_->id } ref $jobs eq 'ARRAY' ? @$jobs : $jobs->all;
    my $comments = $self->search({job_id => {in => \@job_ids}}, {order_by => 'me.id', select => [qw(text job_id)]});
    my $bugs     = $self->result_source->schema->resultset('Bugs');

    my (%res, %bugdetails);
    while (my $comment = $comments->next) {
        my ($bugrefs, $res) = ($comment->bugrefs, $res{$comment->job_id} //= {});
        if (@$bugrefs) {
            my $bugs_of_job = ($res->{bugs} //= {});
            for my $bug (@$bugrefs) {
                $bugdetails{$bug} ||= $bugs->get_bug($bug) if $args->{bugdetails};
                $bugs_of_job->{$bug} = 1;
            }
            $res->{bugdetails} = \%bugdetails;
            $res->{reviewed}   = 1;
        }
        elsif (my $label = $comment->label) {
            $res->{label}    = $label;
            $res->{reviewed} = 1;
        }
        else {
            $res->{comments}++;
        }
        # note: Previous labels are overwritten here so only the most recent label is returned.
    }
    return \%res;
}

1;
