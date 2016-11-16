# Copyright (C) 2015-2016 SUSE LLC
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
use OpenQA::Utils;
use Scalar::Util qw(looks_like_number);


sub _map_tags_into_build {
    my ($res, $tags) = @_;

    for my $build (keys %$res) {
        if ($tags->{$build}) {
            $res->{$build}->{tag} = $tags->{$build};
        }
    }
    return;
}

sub index {
    my ($self) = @_;

    my $limit_builds = $self->param('limit_builds');
    $limit_builds = 3 unless looks_like_number($limit_builds);
    my $time_limit_days = $self->param('time_limit_days');
    $time_limit_days = 14 unless looks_like_number($time_limit_days);
    $self->app->log->debug("Retrieving results for up to $limit_builds builds up to $time_limit_days days old");
    my $only_tagged = $self->param('only_tagged') // 0;
    my $show_tags   = $self->param('show_tags')   // $only_tagged;
    my $group_params = $self->every_param('group');

    my @results;
    my $groups = $self->stash('job_groups_and_parents');

    for my $group (@$groups) {
        if (@$group_params) {
            next unless grep { $_ eq '' || $group->name =~ /$_/ } @$group_params;
        }
        my $tags = $group->tags;
        my $build_results = OpenQA::BuildResults::compute_build_results($group, $limit_builds, $time_limit_days, $only_tagged ? $tags : undef);

        my $res = $build_results->{result};
        if ($show_tags) {
            _map_tags_into_build($res, $tags);
        }
        push(@results, $build_results) if %{$build_results->{result}};
    }
    $self->stash('limit_builds',    $limit_builds);
    $self->stash('time_limit_days', $time_limit_days);
    $self->stash('results',         \@results);
    $self->respond_to(
        json => {json     => {results => \@results}},
        html => {template => 'main/index'});
}

sub group_overview {
    my ($self, $resultset, $template) = @_;

    my $limit_builds = $self->param('limit_builds');
    $limit_builds = 10 unless looks_like_number($limit_builds);
    my $time_limit_days = $self->param('time_limit_days');
    $time_limit_days = 0 unless looks_like_number($time_limit_days);

    $self->app->log->debug("Retrieving results for up to $limit_builds builds up to $time_limit_days days old");
    my $only_tagged = $self->param('only_tagged') // 0;
    my $group = $self->db->resultset($resultset)->find($self->param('groupid'));
    return $self->reply->not_found unless $group;

    my @comments;
    my @pinned_comments;
    my $tags;
    if ($group->can('comments')) {
        for my $comment ($group->comments->all) {
            # find pinned comments
            if ($comment->user->is_operator && CORE::index($comment->text, 'pinned-description') >= 0) {
                push(@pinned_comments, $comment);
            }
            else {
                push(@comments, $comment);
            }
        }
        $tags = $group->tags;
    }

    my $cbr      = OpenQA::BuildResults::compute_build_results($group, $limit_builds, $time_limit_days, $only_tagged ? $tags : undef);
    my $res      = $cbr->{result};
    my $max_jobs = $cbr->{max_jobs};
    $self->stash(children => $cbr->{children});

    _map_tags_into_build($res, $tags);
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
    if ($group->can('children')) {
        my @child_groups = $group->children->all;
        $self->stash('child_groups', \@child_groups);
    }
    my $desc = $group->rendered_description;
    $self->stash('description', $desc);
    $self->respond_to(
        json => sub {
            @comments        = map($_->hash, @comments);
            @pinned_comments = map($_->hash, @pinned_comments);
            $self->render(
                json => {
                    group           => $self->stash('group'),
                    result          => $self->stash('result'),
                    max_jobs        => $self->stash('max_jobs'),
                    description     => $group->description,
                    comments        => \@comments,
                    pinned_comments => \@pinned_comments
                });
        },
        html => {template => $template});
}

sub job_group_overview {
    my ($self) = @_;
    $self->group_overview('JobGroups', 'main/group_overview');
}

sub parent_group_overview {
    my ($self) = @_;
    $self->group_overview('JobGroupParents', 'main/parent_group_overview');
}

1;
# vim: set sw=4 et:
