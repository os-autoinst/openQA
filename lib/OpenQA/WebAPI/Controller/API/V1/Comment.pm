# Copyright (C) 2016 SUSE LLC
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
use Date::Format;
use Mojo::Base 'Mojolicious::Controller';
use OpenQA::Utils;
use OpenQA::IPC;
use OpenQA::Utils qw(href_to_bugref);

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

sub comments {
    my ($self) = @_;
    if ($self->param('job_id')) {
        return $self->obj_comments('job_id', 'Jobs', 'Job');
    }
    else {
        return $self->obj_comments('group_id', 'JobGroups', 'Job group');
    }
}

# Returns the text and properties for a comment specified by job/group id and comment id (including rendered markdown).
sub text {
    my ($self) = @_;
    my $comments = $self->comments();
    return unless $comments;
    my $comment_id = $self->param('comment_id');
    my $comment    = $comments->find($comment_id);
    return $self->render(json => {error => "Comment $comment_id does not exist"}, status => 404) unless $comment;

    $self->render(
        json => {
            text             => $comment->text,
            renderedMarkdown => $comment->rendered_markdown,
            created          => $comment->t_created->strftime("%Y-%m-%d %H:%M:%S %z"),
            updated          => $comment->t_updated->strftime("%Y-%m-%d %H:%M:%S %z"),
            userName         => $comment->user->name
        });
}

# Adds a new comment to the specified job/group.
sub create {
    my ($self) = @_;
    my $comments = $self->comments();
    return unless $comments;

    my $text = $self->param('text');
    return $self->render(json => {error => 'No/invalid text specified'}, status => 400) unless $text;

    my $res = $comments->create(
        {
            text    => href_to_bugref($text),
            user_id => $self->current_user->id
        });
    $self->emit_event('openqa_user_new_comment', {id => $res->id});
    $self->render(json => {id => $res->id});
}

# Updates an existing comment specified by job/group id and comment id
sub update {
    my ($self) = @_;
    my $comments = $self->comments();
    return unless $comments;

    my $text = $self->param('text');
    return $self->render(json => {error => "No/invalid text specified"}, status => 400) unless $text;

    my $comment_id = $self->param('comment_id');
    my $comment    = $comments->find($self->param('comment_id'));
    return $self->render(json => {error => "Comment $comment_id does not exist"}, status => 404) unless $comment;
    return $self->render(json => {error => "Forbidden (must be author)"}, status => 403)
      unless ($comment->user_id == $self->current_user->id);
    my $res = $comment->update({text => href_to_bugref($text)});
    $self->emit_event('openqa_user_update_comment', {id => $comment->id});
    $self->render(json => {id => $res->id});
}

# Deletes an existing comment specified by job/group id and comment id
sub delete {
    my ($self) = @_;
    my $comments = $self->comments();
    return unless $comments;

    my $comment_id = $self->param('comment_id');
    my $comment    = $comments->find($self->param('comment_id'));
    return $self->render(json => {error => "Comment $comment_id does not exist"}, status => 404) unless $comment;
    my $res = $comment->delete();
    $self->emit_event('openqa_user_delete_comment', {id => $res->id});
    $self->render(json => {id => $res->id});
}

1;
# vim: set sw=4 et:
