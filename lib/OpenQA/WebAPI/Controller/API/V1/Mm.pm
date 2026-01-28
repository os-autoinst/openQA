# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::API::V1::Mm;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use OpenQA::Jobs::Constants qw(RUNNING SCHEDULED DONE);
use OpenQA::JobDependencies::Constants qw(PARALLEL);
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

my %STATE_MAPPING = (running => RUNNING, scheduled => SCHEDULED);

sub get_children_status ($self) {
    my $state = $STATE_MAPPING{$self->stash('state')} // DONE;
    my $jobid = $self->stash('job_id');
    my $jobs = $self->schema->resultset('Jobs');
    my %attr = (columns => ['id'], join => 'parents');
    my @res = $jobs->search({'parents.parent_job_id' => $jobid, state => $state}, \%attr);
    return $self->render(json => {jobs => [map { $_->id } @res]}, status => 200);
}

sub _find_jobs ($self, $id_column, $dependency_column, $columns, $join) {
    my $job_id = $self->stash('job_id');
    my $jobs = $self->schema->resultset('Jobs');
    [$jobs->search({$id_column => $job_id, $dependency_column => PARALLEL}, {columns => $columns, join => $join})->all];
}

=over 4

=item get_children()

Returns a list of jobs that are configured as children of a given job identified by job_id. For the
children jobs, their id and state is returned in a JSON block.

=back

=cut

sub get_children ($self) {
    my $jobs = $self->_find_jobs('parents.parent_job_id', 'parents.dependency', ['id', 'state'], 'parents');
    $self->render(json => {jobs => {map { ($_->id, $_->state) } @$jobs}}, status => 200);
}

=over 4

=item get_parents()

Returns a list of jobs that are configured as parents of a given job identified by job_id. For the
parents jobs, their id is returned in a JSON block.

=back

=cut

sub get_parents ($self) {
    my $jobs = $self->_find_jobs('children.child_job_id', 'children.dependency', ['id'], 'children');
    return $self->render(json => {jobs => [map { $_->id } @$jobs]}, status => 200);
}

1;
