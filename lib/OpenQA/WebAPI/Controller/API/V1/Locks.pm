# Copyright 2015-2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::API::V1::Locks;
use Mojo::Base 'Mojolicious::Controller';

use OpenQA::Resource::Locks;

=pod

=head1 NAME

OpenQA::WebAPI::Controller::API::V1::Locks

=head1 SYNOPSIS

  use OpenQA::WebAPI::Controller::API::V1::Locks;

=head1 DESCRIPTION

OpenQA API implementation for locking and mutex mechanisms.

=head1 METHODS

=over 4

=item mutex_action()

Perform the mutex operations of "lock" or "unlock" as requested. Returns a
code of 200 on success, 410 on error and 409 on mutex unavailable.

=back

=cut

sub mutex_action {
    my ($self) = @_;

    my $name = $self->stash('name');
    my $jobid = $self->stash('job_id');

    my $validation = $self->validation;
    $validation->required('action')->in(qw(lock unlock));
    $validation->optional('where')->like(qr/^[0-9]+$/);
    return $self->reply->validation_error if $validation->has_error;

    my $action = $validation->param('action');
    my $where = $validation->param('where') // '';
    my $res;
    if ($action eq 'lock') { $res = OpenQA::Resource::Locks::lock($name, $jobid, $where) }
    else { $res = OpenQA::Resource::Locks::unlock($name, $jobid, $where) }

    return $self->render(text => 'ack', status => 200) if $res > 0;
    return $self->render(text => 'nack', status => 410) if $res < 0;
    return $self->render(text => 'nack', status => 409);
}

=over 4

=item mutex_create()

Creates a named mutex resource associated with the current job. Returns a code
of 200 on success and 409 on error.

=back

=cut

sub mutex_create {
    my ($self) = @_;

    my $jobid = $self->stash('job_id');

    my $validation = $self->validation;
    $validation->required('name')->like(qr/^[0-9a-zA-Z_]+$/);
    return $self->reply->validation_error if $validation->has_error;

    my $name = $validation->param('name');

    my $res = OpenQA::Resource::Locks::create($name, $jobid);
    return $self->render(text => 'ack', status => 200) if $res;
    return $self->render(text => 'nack', status => 409);
}

=over 4

=item barrier_wait()

Blocks execution of the calling job until the method is called by all tasks
using the barrier referenced by "name". Returns a 200 code on success, 410
on error on 409 when the referenced barrier does not exist.

=back

=cut

sub barrier_wait {
    my ($self) = @_;

    my $jobid = $self->stash('job_id');
    my $name = $self->stash('name');

    my $validation = $self->validation;
    $validation->optional('where')->like(qr/^[0-9]+$/);
    $validation->optional('check_dead_job')->like(qr/^[0-9]+$/);
    return $self->reply->validation_error if $validation->has_error;

    my $where = $validation->param('where') // '';
    my $check_dead_job = $validation->param('check_dead_job') // 0;

    my $res = OpenQA::Resource::Locks::barrier_wait($name, $jobid, $where, $check_dead_job);

    return $self->render(text => 'ack', status => 200) if $res > 0;
    return $self->render(text => 'nack', status => 410) if $res < 0;
    return $self->render(text => 'nack', status => 409);
}

=over 4

=item barrier_create()

Creates a new barrier resource for a group of tasks referenced by the argument "task."
Returns a code of 200 on success or of 409 on error.

=back

=cut

sub barrier_create {
    my ($self) = @_;

    my $jobid = $self->stash('job_id');

    my $validation = $self->validation;
    $validation->required('name')->like(qr/^[0-9a-zA-Z_]+$/);
    $validation->required('tasks')->like(qr/^[0-9]+$/);
    return $self->reply->validation_error if $validation->has_error;

    my $tasks = $validation->param('tasks');
    my $name = $validation->param('name');

    my $res = OpenQA::Resource::Locks::barrier_create($name, $jobid, $tasks);
    return $self->render(text => 'ack', status => 200) if $res;
    return $self->render(text => 'nack', status => 409);
}

=over 4

=item barrier_destroy()

Removes a barrier given its name.

=back

=cut

sub barrier_destroy {
    my ($self) = @_;

    my $jobid = $self->stash('job_id');
    my $name = $self->stash('name');

    my $validation = $self->validation;
    $validation->optional('where')->like(qr/^[0-9]+$/);
    return $self->reply->validation_error if $validation->has_error;

    my $where = $validation->param('where') // '';
    my $res = OpenQA::Resource::Locks::barrier_destroy($name, $jobid, $where);

    return $self->render(text => 'ack', status => 200);
}

1;
