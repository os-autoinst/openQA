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

sub comments {
    my ($self) = @_;

    my $table = $self->param('job_id') ? "Jobs" : "JobGroups";
    my $id = int($self->param('job_id') // $self->param('group_id'));
    my $job = $self->app->schema->resultset($table)->find($id);
    if (!$job) {
        $self->render(json => {error => "Job $id does not exist"}, status => 404);
        return 0;
    }
    return $job->comments;
}

# Returns the text for a comment specified by job/group id and comment id (including rendered markdown).
sub text {
    my ($self) = @_;
    my $comments = $self->comments();
    return unless $comments;
    my $comment_id = $self->param('comment_id');
    my $comment    = $comments->find($comment_id);
    return $self->render(json => {error => "Comment $comment_id does not exist"}, status => 404) unless $comment;

    $self->render(
        json => {
            text              => $comment->text,
            rendered_markdown => $comment->rendered_markdown
        });
}

# Adds a new comment to the specified job/group.
sub create {
    my ($self) = @_;
    my $comments = $self->comments();

    my $text = $self->hparams()->{'text'};
    return $self->render(json => {error => 'No/invalid text specified'}, status => 400) unless $text;

    my $res = $comments->create(
        {
            text => $text,
            ,
            user_id => $self->current_user->id
        });
    $self->render(json => {id => $res->id});
}

# Updates an existing comment specified by job/group id and comment id
sub update {
    my ($self) = @_;
    my $comments = $self->comments();

    my $text = $self->hparams()->{'text'};
    return $self->render(json => {error => "No/invalid text specified"}, status => 400) unless $text;

    my $comment = $comments->find($self->param('comment_id'));
    return $self->render(json => {error => "Forbidden (must be author)"}, status => 403) unless ($comment->user_id == $self->current_user->id);
    my $res = $comment->update(
        {
            text => $text,
            t_updated => DateTime->now(time_zone => 'floating')});
    $self->render(json => {id => $res->id});
}

# Deletes an existing comment specified by job/group id and comment id
sub delete {
    my ($self) = @_;
    my $comments = $self->comments();

    my $res = $comments->find($self->param('comment_id'))->delete();
    $self->render(json => {id => $res->id});
}

1;
# vim: set sw=4 et:
