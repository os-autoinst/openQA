# Copyright (C) 2015-2017 SUSE LLC
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
use Scalar::Util 'looks_like_number';

sub _map_tags_into_build {
    my ($results, $tags) = @_;

    for my $res (@$results) {
        if (my $full_tag = $tags->{$res->{key}}) {
            $res->{tag} = $full_tag;
        }
        elsif (my $build_only_tag = $tags->{$res->{build}}) {
            # as fallback we are looking for build and not other criteria we can end
            # up with multiple tags if the build appears more than once, e.g.
            # for each version
            $res->{tag} = $build_only_tag;
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
    my $only_tagged      = $self->param('only_tagged') // 0;
    my $default_expanded = $self->param('default_expanded') // 0;
    my $show_tags        = $self->param('show_tags') // $only_tagged;
    my $group_params     = $self->every_param('group');
    my @results;
    my $groups = $self->stash('job_groups_and_parents');

    for my $group (@$groups) {
        if (@$group_params) {
            next unless grep { $_ eq '' || $group->matches_nested($_) } @$group_params;
        }
        my $tags = $show_tags || $only_tagged ? $group->tags : undef;
        my $build_results
          = OpenQA::BuildResults::compute_build_results($group, $limit_builds, $time_limit_days,
            $only_tagged ? $tags : undef,
            $group_params);

        my $build_results_for_group = $build_results->{build_results};
        if ($show_tags) {
            _map_tags_into_build($build_results_for_group, $tags);
        }
        push(@results, $build_results) if @{$build_results_for_group};
    }
    $self->stash('limit_builds',     $limit_builds);
    $self->stash('time_limit_days',  $time_limit_days);
    $self->stash('default_expanded', $default_expanded);
    $self->stash('results',          \@results);
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
    my $group_id    = $self->param('groupid');
    return $self->reply->not_found unless looks_like_number($group_id);
    my $group = $self->db->resultset($resultset)->find($group_id);
    return $self->reply->not_found unless $group;
    $self->stash('fullscreen', $self->param('fullscreen') // 0);
    my $interval = $self->param('interval') // 60;
    $self->stash('interval', $interval);

    my @comments;
    my @pinned_comments;
    my $tags;
    if ($group->can('comments')) {
        # read paging parameter
        my $page       = int($self->param('comments_page') // 1);
        my $page_limit = int($self->param('comments_limit') // 5);
        return $self->respond_to(json => sub { html => 'Invalid paging parameter specified.' })
          unless $page && $page_limit;

        # find comments
        my $comments_resultset = $self->app->schema->resultset('Comments');
        my $comments           = $comments_resultset->search(
            {
                group_id => $group->id
            },
            {
                page     => $page,
                rows     => $page_limit,
                order_by => {-desc => 't_created'},
            });
        $self->stash('comments_pager', $comments->pager());
        @comments = $comments->all;

        # find "pinned descriptions" (comments by operators with the word 'pinned-description' in it)
        # FIXME: use a join with the user table here to do the check for operator via the database
        for my $comment (
            $comments_resultset->search(
                {
                    group_id => $group->id,
                    text     => {like => '%pinned-description%'},
                }
            )->all
          )
        {
            push(@pinned_comments, $comment) if ($comment->user->is_operator);
        }

    }
    $tags = $group->tags;

    my $cbr = OpenQA::BuildResults::compute_build_results(
        $group, $limit_builds, $time_limit_days,
        $only_tagged ? $tags : undef,
        $self->every_param('group'));
    my $build_results = $cbr->{build_results};
    my $max_jobs      = $cbr->{max_jobs};
    $self->stash(children => $cbr->{children});

    _map_tags_into_build($build_results, $tags);
    $self->stash('build_results', $build_results);
    $self->stash('max_jobs',      $max_jobs);
    my $group_hash = {
        id   => $group->id,
        name => $group->name,
    };
    $self->stash('limit_builds',    $limit_builds);
    $self->stash('only_tagged',     $only_tagged);
    $self->stash('comments',        \@comments);
    $self->stash('pinned_comments', \@pinned_comments);
    if ($group->can('children')) {
        my @child_groups = $group->children->all;
        $self->stash('child_groups', \@child_groups);
    }
    elsif ($group->parent_id) {
        $group_hash->{parent_id}   = $group->parent_id;
        $group_hash->{parent_name} = $group->parent->name;
    }
    $self->stash('group', $group_hash);
    my $desc = $group->rendered_description;
    $self->stash('description', $desc);
    $self->respond_to(
        json => sub {
            @comments        = map($_->hash, @comments);
            @pinned_comments = map($_->hash, @pinned_comments);
            $self->render(
                json => {
                    group           => $group_hash,
                    build_results   => $build_results,
                    max_jobs        => $max_jobs,
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

sub changelog {
    my ($self) = @_;

    my $changelog;
    if (open(my $changelog_file, '<', $self->app->config->{global}->{changelog_file})) {
        read($changelog_file, $changelog, -s $changelog_file);
        close($changelog_file);
    }
    else {
        $changelog = 'No changelog available.';
    }
    $self->stash(changelog => $changelog);
}

1;
# vim: set sw=4 et:
