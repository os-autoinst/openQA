# Copyright (C) 2015 SUSE Linux GmbH
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package OpenQA::WebAPI::Controller::Main;
use strict;
use warnings;
use Mojo::Base 'Mojolicious::Controller';
use Date::Format;
use OpenQA::Schema::Result::Jobs;
use OpenQA::BuildResults;

sub index {
    my ($self) = @_;

    my $limit_builds    = $self->param('limit_builds')    // 3;
    my $time_limit_days = $self->param('time_limit_days') // 14;
    $self->app->log->debug("Retrieving results for up to $limit_builds builds up to $time_limit_days days old");
    my $group_params = $self->every_param('group');

    my @results;
    my $groups = $self->db->resultset('JobGroups')->search({}, {order_by => qw/name/});

    while (my $group = $groups->next) {
        if (@$group_params) {
            next unless grep { $_ eq '' || $group->name =~ /$_/ } @$group_params;
        }
        my $build_results = OpenQA::BuildResults::compute_build_results($self->app, $group, $limit_builds, $time_limit_days);
        push(@results, $build_results) if $build_results;
    }
    $self->stash('results', \@results);
    $self->respond_to(
        json => {json     => {results => \@results}},
        html => {template => 'main/index'});
}

sub group_overview {
    my ($self) = @_;

    my $limit_builds    = $self->param('limit_builds')    // 10;
    my $time_limit_days = $self->param('time_limit_days') // 14;
    $self->app->log->debug("Retrieving results for up to $limit_builds builds up to $time_limit_days days old");
    my $only_tagged = $self->param('only_tagged') // 0;
    my $group = $self->db->resultset('JobGroups')->find($self->param('groupid'));
    return $self->reply->not_found unless $group;

    my $cbr      = OpenQA::BuildResults::compute_build_results($self->app, $group, $limit_builds, $time_limit_days);
    my $res      = $cbr->{result};
    my $max_jobs = $cbr->{max_jobs};
    my @comments;
    my @pinned_comments;
    for my $comment ($group->comments->all) {
        # find pinned comments
        if ($comment->user->is_operator && CORE::index($comment->text, 'pinned-description') >= 0) {
            push(@pinned_comments, $comment);
        }
        else {
            push(@comments, $comment);
        }

        my @tag   = $comment->tag;
        my $build = $tag[0];
        next unless $build;
        # Next line fixes poo#12028
        next unless $res->{$build};
        $self->app->log->debug('Tag found on build ' . $tag[0] . ' of type ' . $tag[1]);
        $self->app->log->debug('description: ' . $tag[2]) if $tag[2];
        if ($tag[1] eq '-important') {
            $self->app->log->debug('Deleting tag on build ' . $build);
            delete $res->{$build}->{tag};
            next;
        }

        # ignore tags on non-existing builds
        if ($res->{$build}) {
            $res->{$build}->{tag} = {type => $tag[1], description => $tag[2]};
        }
    }
    if ($only_tagged) {
        for my $build (keys %$res) {
            next unless $build;
            delete $res->{$build} unless $res->{$build}->{tag};
        }
    }
    $self->stash('result',   $res);
    $self->stash('max_jobs', $max_jobs);
    $self->stash(
        'group',
        {
            id   => $group->id,
            name => $group->name
        });
    $self->stash('limit_builds',    $limit_builds);
    $self->stash('only_tagged',     $only_tagged);
    $self->stash('comments',        \@comments);
    $self->stash('pinned_comments', \@pinned_comments);
    my $desc = $group->rendered_description;
    $self->stash('description', $desc);
    $self->respond_to(
        json => {json     => {result => $res, group => $self->stash('group'), max_jobs => $max_jobs}},
        html => {template => 'main/group_overview'});
}

1;
# vim: set sw=4 et:
