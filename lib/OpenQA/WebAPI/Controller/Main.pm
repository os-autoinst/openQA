# Copyright 2015-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::Main;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Date::Format;
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use OpenQA::BuildResults;
use OpenQA::Utils;
use Mojo::File qw(path);

sub _map_tags_into_build ($results, $tags) {
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
}

sub dashboard_build_results ($self) {
    my $validation = $self->validation;
    $validation->optional('limit_builds')->num;
    $validation->optional('time_limit_days')->like(qr/^[0-9.]+$/);
    $validation->optional('only_tagged');
    $validation->optional('default_expanded');
    $validation->optional('show_tags');
    $validation->optional('group');
    return $self->reply->validation_error({format => $self->accepts('html', 'json')}) if $validation->has_error;

    my $limit_builds = $validation->param('limit_builds') // 3;
    my $time_limit_days = $validation->param('time_limit_days') // 14;
    my $only_tagged = $validation->param('only_tagged') // 0;
    my $default_expanded = $validation->param('default_expanded') // 0;
    my $show_tags = $validation->param('show_tags') // $only_tagged;
    my $group_params = $validation->every_param('group');

    my $groups = $self->stash('job_groups_and_parents');

    my @results;
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
        _map_tags_into_build($build_results_for_group, $tags) if $show_tags;
        push(@results, $build_results) if @{$build_results_for_group};
    }

    $self->stash(
        default_expanded => $default_expanded,
        results => \@results,
    );

    $self->respond_to(
        json => {json => {results => \@results}},
        html => {template => 'main/dashboard_build_results'});
}

sub _group_overview ($self, $resultset, $template) {
    my $validation = $self->validation;
    $validation->optional('limit_builds')->num;
    $validation->optional('time_limit_days')->like(qr/^[0-9.]+$/);
    $validation->optional('only_tagged');
    $validation->optional('fullscreen');
    $validation->optional('interval');
    $validation->optional('comments_page')->num;
    $validation->optional('comments_limit')->num;
    return $self->reply->validation_error({format => $self->accepts('html', 'json')}) if $validation->has_error;

    my $limit_builds = $validation->param('limit_builds') // 10;
    my $time_limit_days = $validation->param('time_limit_days') // 0;
    $self->app->log->debug("Retrieving results for up to $limit_builds builds up to $time_limit_days days old");
    my $only_tagged = $validation->param('only_tagged') // 0;

    my $group_id = $self->stash('groupid');
    return $self->reply->not_found unless my $group = $self->schema->resultset($resultset)->find($group_id);

    my $fullscreen = $validation->param('fullscreen') // 0;
    my $interval = $validation->param('interval') // 60;
    $self->stash(fullscreen => $fullscreen, interval => $interval);

    my $page = $validation->param('comments_page') // 1;
    my $page_limit = $validation->param('comments_limit') // 5;

    $self->inactivity_timeout($ENV{OPENQA_WEBUI_OVERVIEW_INACTIVITY_TIMEOUT} // 90);
    # find comments
    my $comments = $group->comments->search(
        undef,
        {
            page => $page,
            rows => $page_limit,
            order_by => {-desc => 't_created'},
        });
    $self->stash('comments_pager', $comments->pager());
    my @comments = $comments->all;

    # find "pinned descriptions" (comments by operators with the word 'pinned-description' in it)
    # FIXME: use a join with the user table here to do the check for operator via the database
    my @pinned_comments;
    for my $comment ($group->comments->search({text => {like => '%pinned-description%'}})->all) {
        push(@pinned_comments, $comment) if $comment->user->is_operator;
    }

    my $tags = $group->tags;
    my $cbr = OpenQA::BuildResults::compute_build_results(
        $group, $limit_builds, $time_limit_days,
        $only_tagged ? $tags : undef,
        $self->every_param('group'));
    my $build_results = $cbr->{build_results};
    my $max_jobs = $cbr->{max_jobs};
    $self->stash(children => $cbr->{children});

    _map_tags_into_build($build_results, $tags);
    $self->stash(build_results => $build_results, max_jobs => $max_jobs);

    my $is_parent_group = $group->can('children');
    my $comment_context = $is_parent_group ? 'parent_group' : 'group';
    my $comment_context_route_suffix = $comment_context . '_comment';
    my $group_hash = {
        id => $group->id,
        name => $group->name,
        is_parent => $is_parent_group,
        rendered_description => $group->rendered_description
    };
    if (!$is_parent_group && (my $parent = $group->parent)) {
        $group_hash->{parent_id} = $parent->id;
        $group_hash->{parent_name} = $parent->name;
    }
    $self->stash(
        group => $group_hash,
        limit_builds => $limit_builds,
        only_tagged => $only_tagged,
        comments => \@comments,
        pinned_comments => \@pinned_comments,
        comment_context => $comment_context,
        comment_post_action => 'apiv1_post_' . $comment_context_route_suffix,
        comment_put_action => 'apiv1_put_' . $comment_context_route_suffix,
        comment_delete_action => 'apiv1_delete_' . $comment_context_route_suffix
    );
    $self->stash(child_groups => [$group->children->all]) if $is_parent_group;

    $self->respond_to(
        json => sub {
            @comments = map($_->hash, @comments);
            @pinned_comments = map($_->hash, @pinned_comments);
            $self->render(
                json => {
                    group => $group_hash,
                    build_results => $build_results,
                    max_jobs => $max_jobs,
                    description => $group->description,
                    comments => \@comments,
                    pinned_comments => \@pinned_comments
                });
        },
        html => {template => $template});
}

sub job_group_overview ($self) { $self->_group_overview('JobGroups', 'main/group_overview') }
sub parent_group_overview ($self) { $self->_group_overview('JobGroupParents', 'main/parent_group_overview') }

sub changelog ($self) {
    my $file = path($self->app->config->{global}->{changelog_file});
    my $changelog = -r $file ? $file->slurp : 'No changelog available.';
    $self->render(changelog => $changelog);
}

1;
