# Copyright 2016 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::API::V1::Comment;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Date::Format;
use OpenQA::App;
use OpenQA::Utils qw(:DEFAULT href_to_bugref);
use List::Util qw(min);

=pod

=head1 NAME

OpenQA::WebAPI::Controller::API::V1::Comment

=head1 SYNOPSIS

  use OpenQA::WebAPI::Controller::API::V1::Comment;

=head1 DESCRIPTION

Implements openQA API methods for comments handling.

=head1 METHODS

=over 4

=item _obj_comments()

Internal method to extract the comments from a job or job group. Returns an object containing
the comments or a 404 error status if an unexistent job or job group was referenced. Used by
the B<comments()> method.

=back

=cut

sub _obj_comments ($self, $param, $table, $label) {
    my $id = int($self->param($param));
    my $limits = OpenQA::App->singleton->config->{misc_limits};
    my $limit = min($limits->{generic_max_limit}, $self->param('limit') // $limits->{generic_default_limit});
    my $obj = $self->app->schema->resultset($table)->find($id);
    return $obj->search_related(comments => {}, {rows => $limit}) if $obj;
    $self->render(json => {error => "$label $id does not exist"}, status => 404);
    return;
}

=over 4

=item _comments()

Returns a list of comments for a job or a job group given its id. For each comment the
list includes its bug references, date of creation, comment id, rendered markdown text,
text, date of update and the user name that created the comment. Internal method used
by B<list()>.

=back

=cut

sub _comments ($self) {
    return $self->_obj_comments('job_id', 'Jobs', 'Job') if $self->param('job_id');
    return $self->_obj_comments('parent_group_id', 'JobGroupParents', 'Parent group')
      if $self->param('parent_group_id');
    return $self->_obj_comments('group_id', 'JobGroups', 'Job group');
}

=over 4

=item list()

Returns a list of comments for a job or a job group given its id. For each comment the
list includes its bug references, date of creation, comment id,
text, date of update and the user name that created the comment.

Add the optional "render_markdown=1" parameter to include the rendered markdown text
for each comment.

=back

=cut

sub list ($self) {
    my $comments = $self->_comments();
    return unless $comments;
    my $render_markdown = $self->param('render_markdown') // 0;
    $self->render(json => [map { $_->extended_hash($render_markdown) } $comments->all]);
}


=over 4

=item text()

Renders text and properties for a comment specified by job/group id and comment id
including rendered markdown and bug references. Returns a 404 code if the specified
comment does not exist, or 200 on success.

=back

=cut

sub text ($self) {
    my $comments = $self->_comments();
    return unless $comments;
    my $comment_id = $self->param('comment_id');
    my $comment = $comments->find($comment_id);
    return $self->render(json => {error => "Comment $comment_id does not exist"}, status => 404) unless $comment;

    $self->render(json => $comment->extended_hash);
}

=over 4

=item create()

Adds a new comment to the specified job/group. Returns a 200 code with a JSON containing the
new comment id or 400 if no text is specified for the comment.

=back

=cut

sub create ($self) {
    my $comments = $self->_comments();
    return unless $comments;

    my $validation = $self->validation;
    $validation->required('text')->like(qr/^(?!\s*$).+/);
    my $text = $validation->param('text');
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;
    my $txn_guard = $self->schema->txn_scope_guard;
    my $comment = $comments->create(
        {
            text => href_to_bugref($text),
            user_id => $self->current_user->id
        });

    eval { $comment->handle_special_contents($self) };
    return $self->render(json => {error => $@}, status => 400) if $@;
    $self->emit_event('openqa_comment_create', $comment->event_data);
    $txn_guard->commit;
    $self->render(json => {id => $comment->id});
}

=over 4

=item create_many()

Adds new comments to the specified jobs. Returns 200 if all comments have been
created or 400 if not all comments could be created. Returns a JSON object with
the created and failed comment IDs or an error message in case a fatal error
occurred.

All comments will have the same text which is passed via the mandatory C<text>
parameter.

At this point only job comments are supported. The job IDs are specified by
passing one or more C<job_id> parameters.

=back

=cut

sub create_many ($self) {
    my $validation = $self->validation;
    $validation->required('text')->like(qr/^(?!\s*$).+/);
    $validation->required('job_id')->num(0, undef);
    $validation->optional('restartRequested')->in(0, 1);
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;

    my $text = $validation->param('text');
    my $job_ids = $validation->every_param('job_id');
    my $wanna_restart = $validation->param('restartRequested');
    my $schema = $self->schema;
    my $comments = $schema->resultset('Comments');
    my (@created, @failed, @failed_restart);
    for my $job_id (@$job_ids) {
        my $txn_guard = $schema->txn_scope_guard;
        eval {
            my $comment = $comments->create(
                {
                    job_id => $job_id,
                    text => href_to_bugref($text),
                    user_id => $self->current_user->id
                });
            $comment->handle_special_contents($self);
            $txn_guard->commit;
            push @created, $comment->event_data;
        };
        push @failed, {job_id => $job_id} if $@;
    }

    if ($wanna_restart && $wanna_restart == 1) {
        for my $job_id (@$job_ids) {
            my ($res, $jobs, $auto, $single_job_id, $dup_route);
            my %args = (jobs => $job_id);
            $self->param('jobid', $job_id);
            eval { ($res, $jobs, $auto, $single_job_id, $dup_route) = $self->restart_job(\%args); };
            push @failed_restart, {job_id => $job_id, error => "Failed to restart job: $@"} if ($@);
            $self->emit_event(openqa_job_restart => {id => $single_job_id, result => $res, auto => $auto});
        }
    }

    # create a single event containing all relevant IDs for this action
    my %res = (created => \@created, failed => \@failed, failed_restart => \@failed_restart);
    $self->emit_event('openqa_comments_create', \%res);
    $res{error} = 'Not all comments could be created.' if @failed;
    $self->render(json => \%res, status => (@failed || @failed_restart ? 400 : 200));
}

=over 4

=item update()

Updates an existing comment specified by job/group id and comment id. An update text argument
is required. Returns a 200 code and a JSON on success and 400 if no text was specified, 404 if
the comment to update does not exist and 403 if the update is not requested by the original
author of the comment.

=back

=cut

sub update ($self) {
    my $comments = $self->_comments();
    return unless $comments;

    my $validation = $self->validation;
    $validation->required('text')->like(qr/^(?!\s*$).+/);
    my $text = $validation->param('text');
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;

    my $comment_id = $self->param('comment_id');
    my $comment = $comments->find($self->param('comment_id'));
    return $self->render(json => {error => "Comment $comment_id does not exist"}, status => 404) unless $comment;
    return $self->render(json => {error => 'Forbidden (must be author)'}, status => 403)
      unless ($comment->user_id == $self->current_user->id);
    my $txn_guard = $self->schema->txn_scope_guard;
    my $res = $comment->update({text => href_to_bugref($text)});
    eval { $res->handle_special_contents($self) };
    return $self->render(json => {error => $@}, status => 400) if $@;
    $self->emit_event('openqa_comment_update', $comment->event_data);
    $txn_guard->commit;
    $self->render(json => {id => $res->id});
}

=over 4

=item delete()

Deletes an existing comment specified by job/group id and comment id.

=back

=cut

sub delete ($self) {
    my $comments = $self->_comments();
    return unless $comments;

    my $comment_id = $self->param('comment_id');
    my $comment = $comments->find($self->param('comment_id'));
    return $self->render(json => {error => "Comment $comment_id does not exist"}, status => 404) unless $comment;
    return $self->render(
        json => {error => "Comment $comment_id has 'force_result' label, deleting not allowed"},
        status => 403
    ) if grep { defined } $comment->force_result;
    $self->emit_event('openqa_comment_delete', {id => $comment_id});
    my $res = $comment->delete();
    $self->render(json => {id => $res->id});
}

=over 4

=item delete_many()

Deletes multiple comments by their IDs which are specified by passing one or
more C<id> parameters. Returns a JSON object with the number of deleted comments
or an error message in case a fatal error occurred. Returns a 200 code when all
comments have been deleted and a 400 code if not all comments could be deleted.

=back

=cut

sub delete_many ($self) {
    my $validation = $self->validation;
    $validation->required('id')->num(0, undef);
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;

    my $ids = $validation->every_param('id');
    my $comments = $self->schema->resultset('Comments');
    my $deleted_rows = $comments->search({id => {-in => $ids}, text => {-not_like => '%label:force_result:%'}})->delete;
    my $ok = $deleted_rows && $deleted_rows == scalar(@$ids);

    my %res = (ids => $ids, deleted => int($deleted_rows));
    $self->emit_event('openqa_comments_delete', \%res) if $deleted_rows;
    $res{error} = 'Not all comments could be deleted.' unless $ok;
    $self->render(json => \%res, status => ($ok ? 200 : 400));
}

1;
