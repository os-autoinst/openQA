# Copyright (c) 2015 SUSE LINUX GmbH, Nuernberg, Germany.
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

package OpenQA::WebAPI::Controller::API::V1::Mm;
use Mojo::Base 'Mojolicious::Controller';

use OpenQA::Schema::Result::Jobs;
use OpenQA::Schema::Result::JobDependencies;

# this needs 2 calls to do anything useful
# IMHO it should be replaced with get_children and removed
sub get_children_status {
    my ($self) = @_;
    my $status = $self->stash('status');
    if ($status eq 'running') {
        $status = OpenQA::Schema::Result::Jobs::RUNNING;
    }
    elsif ($status eq 'scheduled') {
        $status = OpenQA::Schema::Result::Jobs::SCHEDULED;
    }
    else {
        $status = OpenQA::Schema::Result::Jobs::DONE;
    }
    my $jobid = $self->stash('job_id');

    my @res = $self->db->resultset('Jobs')->search({'parents.parent_job_id' => $jobid, state => $status}, {columns => ['id'], join => 'parents'});
    my @res_ids = map { $_->id } @res;
    return $self->render(json => {jobs => \@res_ids}, status => 200);
}

sub get_children {
    my ($self) = @_;
    my $jobid = $self->stash('job_id');

    my @res = $self->db->resultset('Jobs')->search({'parents.parent_job_id' => $jobid, 'parents.dependency' => OpenQA::Schema::Result::JobDependencies::PARALLEL}, {columns => ['id', 'state'], join => 'parents'});
    my %res_ids = map { ($_->id, $_->state) } @res;
    return $self->render(json => {jobs => \%res_ids}, status => 200);
}

sub get_parents {
    my ($self) = @_;
    my $jobid = $self->stash('job_id');

    my @res = $self->db->resultset('Jobs')->search({'children.child_job_id' => $jobid, 'children.dependency' => OpenQA::Schema::Result::JobDependencies::PARALLEL}, {columns => ['id'], join => 'children'});
    my @res_ids = map { $_->id } @res;
    return $self->render(json => {jobs => \@res_ids}, status => 200);
}

1;
