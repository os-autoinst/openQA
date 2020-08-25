# Copyright (c) 2015 SUSE LLC
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

use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use OpenQA::Schema::Result::JobDependencies;

=pod

=head1 NAME

OpenQA::WebAPI::Controller::API::V1::Mm

=head1 SYNOPSIS

  use OpenQA::WebAPI::Controller::API::V1::Mm;

=head1 DESCRIPTION

OpenQA API implementation for multi machine methods.

=head1 METHODS

=over 4

=item get_children_status()

Given a job id and a status text (running, scheduled or done), this method returns a list of
children jobs' job ids that have the same status as the parent job. Return a 200 code and a
JSON block with the list.

=back

=cut

# this needs 2 calls to do anything useful
# IMHO it should be replaced with get_children and removed
sub get_children_status {
    my ($self) = @_;
    my $status = $self->stash('status');
    if ($status eq 'running') {
        $status = OpenQA::Jobs::Constants::RUNNING;
    }
    elsif ($status eq 'scheduled') {
        $status = OpenQA::Jobs::Constants::SCHEDULED;
    }
    else {
        $status = OpenQA::Jobs::Constants::DONE;
    }
    my $jobid = $self->stash('job_id');

    my @res = $self->schema->resultset('Jobs')
      ->search({'parents.parent_job_id' => $jobid, state => $status}, {columns => ['id'], join => 'parents'});
    my @res_ids = map { $_->id } @res;
    return $self->render(json => {jobs => \@res_ids}, status => 200);
}

=over 4

=item get_children()

Returns a list of jobs that are configured as children of a given job identified by job_id. For the
children jobs, their id and state is returned in a JSON block.

=back

=cut

sub get_children {
    my ($self) = @_;
    my $jobid = $self->stash('job_id');

    my @res
      = $self->schema->resultset('Jobs')
      ->search(
        {'parents.parent_job_id' => $jobid, 'parents.dependency' => OpenQA::JobDependencies::Constants::PARALLEL},
        {columns                 => ['id', 'state'], join        => 'parents'});
    my %res_ids = map { ($_->id, $_->state) } @res;
    return $self->render(json => {jobs => \%res_ids}, status => 200);
}

=over 4

=item get_parents()

Returns a list of jobs that are configured as parents of a given job identified by job_id. For the
parents jobs, their id is returned in a JSON block.

=back

=cut

sub get_parents {
    my ($self) = @_;
    my $jobid = $self->stash('job_id');

    my @res
      = $self->schema->resultset('Jobs')
      ->search(
        {'children.child_job_id' => $jobid, 'children.dependency' => OpenQA::JobDependencies::Constants::PARALLEL},
        {columns                 => ['id'], join                  => 'children'});
    my @res_ids = map { $_->id } @res;
    return $self->render(json => {jobs => \@res_ids}, status => 200);
}

1;
