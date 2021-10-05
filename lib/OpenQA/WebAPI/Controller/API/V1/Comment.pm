# Copyright 2016 SUSE LLC
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

package OpenQA::WebAPI::Controller::API::V1::Comment;
use Mojo::Base 'Mojolicious::Controller';

use Date::Format;
use OpenQA::Utils qw(:DEFAULT href_to_bugref);

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

sub obj_comments {
    my ($self, $param, $table, $label) = @_;
    my $id  = int($self->param($param));
    my $obj = $self->app->schema->resultset($table)->find($id);
    if (!$obj) {
        $self->render(json => {error => "$label $id does not exist"}, status => 404);
        return;
    }
    return $obj->comments;
}

=over 4

=item comments()

Returns a list of comments for a job or a job group given its id. For each comment the
list includes its bug references, date of creation, comment id, rendered markdown text,
text, date of update and the user name that created the comment. Internal method used
by B<list()>.

=back

=cut

sub comments {
    my ($self) = @_;
    if ($self->param('job_id')) {
        return $self->obj_comments('job_id', 'Jobs', 'Job');
    }
    elsif ($self->param('parent_group_id')) {
        return $self->obj_comments('parent_group_id', 'JobGroupParents', 'Parent group');
    }
    else {
        return $self->obj_comments('group_id', 'JobGroups', 'Job group');
    }
}

=over 4

=item list()

Returns a list of comments for a job or a job group given its id. For each comment the
list includes its bug references, date of creation, comment id, rendered markdown text,
text, date of update and the user name that created the comment.

=back

=cut

sub list {
    my ($self) = @_;
    my $comments = $self->comments();
    return unless $comments;

    my @comments;
    while (my $comment = $comments->next) {
        push(@comments, $comment->extended_hash);
    }
    $self->render(json => \@comments);
}

=over 4

=item text()

Renders text and properties for a comment specified by job/group id and comment id
including rendered markdown and bug references. Returns a 404 code if the specified
comment does not exist, or 200 on success.

=back

=cut

sub text {
    my ($self) = @_;
    my $comments = $self->comments();
    return unless $comments;
    my $comment_id = $self->param('comment_id');
    my $comment    = $comments->find($comment_id);
    return $self->render(json => {error => "Comment $comment_id does not exist"}, status => 404) unless $comment;

    $self->render(json => $comment->extended_hash);
}

sub _insert_bugs_for_comment {
    my ($self, $comment) = @_;

    my $bugs = $self->app->schema->resultset('Bugs');
    if (my $bugrefs = $comment->bugrefs) {
        for my $bug (@$bugrefs) {
            $bugs->get_bug($bug);
        }
    }
}

=over 4

=item create()

Adds a new comment to the specified job/group. Returns a 200 code with a JSON containing the
new comment id or 400 if no text is specified for the comment.

=back

=cut

sub create {
    my ($self) = @_;
    my $comments = $self->comments();
    return unless $comments;

    my $validation = $self->validation;
    $validation->required('text')->like(qr/^(?!\s*$).+/);
    my $text = $validation->param('text');
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;

    my $res = $comments->create(
        {
            text    => href_to_bugref($text),
            user_id => $self->current_user->id
        });

    $self->_insert_bugs_for_comment($res);
    $self->emit_event('openqa_comment_create', {id => $res->id});
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

sub update {
    my ($self) = @_;
    my $comments = $self->comments();
    return unless $comments;

    my $validation = $self->validation;
    $validation->required('text')->like(qr/^(?!\s*$).+/);
    my $text = $validation->param('text');
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;

    my $comment_id = $self->param('comment_id');
    my $comment    = $comments->find($self->param('comment_id'));
    return $self->render(json => {error => "Comment $comment_id does not exist"}, status => 404) unless $comment;
    return $self->render(json => {error => "Forbidden (must be author)"},         status => 403)
      unless ($comment->user_id == $self->current_user->id);
    my $res = $comment->update({text => href_to_bugref($text)});
    $self->_insert_bugs_for_comment($comment);
    $self->emit_event('openqa_comment_update', {id => $comment->id});
    $self->render(json => {id => $res->id});
}

=over 4

=item delete()

Deletes an existing comment specified by job/group id and comment id.

=back

=cut

sub delete {
    my ($self) = @_;
    my $comments = $self->comments();
    return unless $comments;

    my $comment_id = $self->param('comment_id');
    my $comment    = $comments->find($self->param('comment_id'));
    return $self->render(json => {error => "Comment $comment_id does not exist"}, status => 404) unless $comment;
    $self->emit_event('openqa_comment_delete', {id => $comment_id});
    my $res = $comment->delete();
    $self->render(json => {id => $res->id});
}

1;
