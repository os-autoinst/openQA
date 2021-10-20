# Copyright 2016 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::API::V1::Comment;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Date::Format;
use OpenQA::Utils qw(:DEFAULT href_to_bugref);
use OpenQA::Jobs::Constants;

=pod

=head1 NAME

OpenQA::WebAPI::Controller::API::V1::Comment

=head1 SYNOPSIS

  use OpenQA::WebAPI::Controller::API::V1::Comment;

=head1 DESCRIPTION

Implements openQA API methods for comments handling.

=head1 METHODS

=over 4

=item obj_comments()

Internal method to extract the comments from a job or job group. Returns an object containing
the comments or a 404 error status if an unexistent job or job group was referenced. Used by
the B<comments()> method.

=back

=cut

sub obj_comments ($self, $param, $table, $label) {
    my $id = int($self->param($param));
    my $obj = $self->app->schema->resultset($table)->find($id);
    return $obj->comments if $obj;
    $self->render(json => {error => "$label $id does not exist"}, status => 404);
    return;
}

=over 4

=item comments()

Returns a list of comments for a job or a job group given its id. For each comment the
list includes its bug references, date of creation, comment id, rendered markdown text,
text, date of update and the user name that created the comment. Internal method used
by B<list()>.

=back

=cut

sub comments ($self) {
    return $self->obj_comments('job_id', 'Jobs', 'Job') if $self->param('job_id');
    return $self->obj_comments('parent_group_id', 'JobGroupParents', 'Parent group') if $self->param('parent_group_id');
    return $self->obj_comments('group_id', 'JobGroups', 'Job group');
}

=over 4

=item list()

Returns a list of comments for a job or a job group given its id. For each comment the
list includes its bug references, date of creation, comment id, rendered markdown text,
text, date of update and the user name that created the comment.

=back

=cut

sub list ($self) {
    my $comments = $self->comments();
    return unless $comments;
    $self->render(json => [map { $_->extended_hash } $comments->all]);
}

=over 4

=item text()

Renders text and properties for a comment specified by job/group id and comment id
including rendered markdown and bug references. Returns a 404 code if the specified
comment does not exist, or 200 on success.

=back

=cut

sub text ($self) {
    my $comments = $self->comments();
    return unless $comments;
    my $comment_id = $self->param('comment_id');
    my $comment = $comments->find($comment_id);
    return $self->render(json => {error => "Comment $comment_id does not exist"}, status => 404) unless $comment;

    $self->render(json => $comment->extended_hash);
}

sub _handle_special_comments ($self, $comment) {
    my $ret = $self->_control_job_result($comment);
    return $ret if $ret;
    $self->_insert_bugs_for_comment($comment);
}

sub _control_job_result ($self, $comment) {
    return undef unless my ($new_result, $description) = $comment->force_result;
    return undef unless $new_result;
    die "Invalid result '$new_result' for force_result\n"
      unless !!grep { /$new_result/ } OpenQA::Jobs::Constants::RESULTS;
    die "force_result labels only allowed for operators\n" unless $self->is_operator;
    my $force_result_re = OpenQA::App->singleton->config->{global}->{force_result_regex} // '';
    die "force_result description '$description' does not match pattern '$force_result_re'\n"
      unless ($description // '') =~ /$force_result_re/;
    my $job = $comment->job;
    die "force_result only allowed on finished jobs\n" unless $job->state eq OpenQA::Jobs::Constants::DONE;
    $job->update_result($new_result);
    return undef;
}

sub _insert_bugs_for_comment ($self, $comment) {
    my $bugs = $self->app->schema->resultset('Bugs');
    if (my $bugrefs = $comment->bugrefs) {
        $bugs->get_bug($_) for @$bugrefs;
    }
}

=over 4

=item create()

Adds a new comment to the specified job/group. Returns a 200 code with a JSON containing the
new comment id or 400 if no text is specified for the comment.

=back

=cut

sub create ($self) {
    my $comments = $self->comments();
    return unless $comments;

    my $validation = $self->validation;
    $validation->required('text')->like(qr/^(?!\s*$).+/);
    my $text = $validation->param('text');
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;
    my $txn_guard = $self->schema->txn_scope_guard;
    my $res = $comments->create(
        {
            text => href_to_bugref($text),
            user_id => $self->current_user->id
        });

    eval { $self->_handle_special_comments($res) };
    return $self->render(json => {error => $@}, status => 400) if $@;
    $self->emit_event('openqa_comment_create', {id => $res->id});
    $txn_guard->commit;
    $self->render(json => {id => $res->id});
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
    my $comments = $self->comments();
    return unless $comments;

    my $validation = $self->validation;
    $validation->required('text')->like(qr/^(?!\s*$).+/);
    my $text = $validation->param('text');
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;

    my $comment_id = $self->param('comment_id');
    my $comment = $comments->find($self->param('comment_id'));
    return $self->render(json => {error => "Comment $comment_id does not exist"}, status => 404) unless $comment;
    return $self->render(json => {error => "Forbidden (must be author)"}, status => 403)
      unless ($comment->user_id == $self->current_user->id);
    my $txn_guard = $self->schema->txn_scope_guard;
    my $res = $comment->update({text => href_to_bugref($text)});
    eval { $self->_handle_special_comments($res) };
    return $self->render(json => {error => $@}, status => 400) if $@;
    $self->emit_event('openqa_comment_update', {id => $comment->id});
    $txn_guard->commit;
    $self->render(json => {id => $res->id});
}

=over 4

=item delete()

Deletes an existing comment specified by job/group id and comment id.

=back

=cut

sub delete ($self) {
    my $comments = $self->comments();
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

1;
