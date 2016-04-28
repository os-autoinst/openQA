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

sub _group_result {
    my ($self, $group, $limit) = @_;

    my $time_limit_days = $self->param('time_limit_days') // 14;
    $self->app->log->debug("Retrieving results for up to $limit builds up to $time_limit_days days old");
    my $timecond = {">" => time2str('%Y-%m-%d %H:%M:%S', time - 24 * 3600 * $time_limit_days, 'UTC')};

    my %res;
    my $jobs = $group->jobs->search({"me.t_created" => $timecond,});
    my $builds = $self->db->resultset('JobSettings')->search(
        {
            job_id => {-in => $jobs->get_column('id')->as_query},
            key    => 'BUILD'
        },
        {
            select => ['value', {min => 't_created', -as => 'first_hit'}],
            as     => [qw/value first_hit/],
            order_by => {-desc => 'first_hit'},
            group_by => [qw/value/]});
    my $max_jobs = 0;
    my $buildnr  = 0;
    for my $b (map { $_->value } $builds->all) {
        my $jobs = $self->db->resultset('Jobs')->search(
            {
                'settings.key'   => 'BUILD',
                'settings.value' => $b,
                'me.group_id'    => $group->id,
                'me.clone_id'    => undef,
            },
            {join => qw/settings/, order_by => 'me.id DESC'});
        my %jr = (oldest => DateTime->now, passed => 0, failed => 0, inprogress => 0, labeled => 0);

        my $count = 0;
        my %seen;
        my %settings;
        my $keys = $self->db->resultset('JobSettings')->search(
            {
                job_id => {-in => [map { $_->id } $jobs->all]},
                key    => [qw/DISTRI VERSION ARCH FLAVOR MACHINE/]});
        while (my $line = $keys->next) {
            $settings{$line->job_id}->{$line->key} = $line->value;
        }
        # prefetch comments to count. Any comment is considered a label here
        # so a build is considered as 'reviewed' if all failures have at least
        # a comment. This could be improved to distinguish between
        # "only-labels", "mixed" and such
        my $c = $self->db->resultset("Comments")->search({job_id => {in => [map { $_->id } $jobs->all]}});
        my %labels;
        while (my $comment = $c->next) {
            $labels{$comment->job_id}++;
        }
        $jobs->reset;

        while (my $job = $jobs->next) {
            my $jhash = $settings{$job->id};
            $jr{distri}  //= $jhash->{DISTRI};
            $jr{version} //= $jhash->{VERSION};
            my $key = $job->test . "-" . $jhash->{ARCH} . "-" . $jhash->{FLAVOR} . "-" . $jhash->{MACHINE};
            next if $seen{$key}++;

            $count++;
            $jr{oldest} = $job->t_created if $job->t_created < $jr{oldest};
            if ($job->state eq OpenQA::Schema::Result::Jobs::DONE) {
                if ($job->result eq OpenQA::Schema::Result::Jobs::PASSED) {
                    $jr{passed}++;
                    next;
                }
                if (   $job->result eq OpenQA::Schema::Result::Jobs::FAILED
                    || $job->result eq OpenQA::Schema::Result::Jobs::INCOMPLETE)
                {
                    $jr{failed}++;
                    $jr{labeled}++ if $labels{$job->id};
                    next;
                }
                if (grep { $job->result eq $_ } OpenQA::Schema::Result::Jobs::INCOMPLETE_RESULTS) {
                    next;    # ignore the rest
                }
            }
            if (   $job->state eq OpenQA::Schema::Result::Jobs::CANCELLED
                || $job->state eq OpenQA::Schema::Result::Jobs::OBSOLETED)
            {
                next;        # ignore
            }
            if ($job->state eq OpenQA::Schema::Result::Jobs::SCHEDULED || $job->state eq OpenQA::Schema::Result::Jobs::RUNNING) {
                $jr{inprogress}++;
                next;
            }
            $self->app->log->error("MISSING S:" . $job->state . " R:" . $job->result);
        }
        $jr{reviewed} = $jr{failed} > 0 && $jr{labeled} == $jr{failed};
        $res{$b} = \%jr;
        $max_jobs = $count if ($count > $max_jobs);
        last if (++$buildnr >= $limit);
    }
    $res{_max} = $max_jobs if %res;

    return \%res;

}

sub index {
    my ($self) = @_;

    my $limit_builds = $self->param('limit_builds') // 3;
    my @results;

    my $groups = $self->db->resultset('JobGroups')->search({}, {order_by => qw/name/});
    while (my $group = $groups->next) {
        my $res = $self->_group_result($group, $limit_builds);
        if (%$res) {
            $res->{_group} = $group;
            push(@results, $res);
        }
    }
    $self->stash('results', \@results);
}

sub group_overview {
    my ($self) = @_;

    my $limit_builds = $self->param('limit_builds') // 10;
    my $group = $self->db->resultset('JobGroups')->find($self->param('groupid'));
    return $self->reply->not_found unless $group;

    my $res = $self->_group_result($group, $limit_builds);
    my @comments = $group->comments->all;
    for my $comment (@comments) {
        my @tag   = $comment->tag;
        my $build = $tag[0];
        next unless $build;
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
    $self->stash('result',   $res);
    $self->stash('group',    $group);
    $self->stash('comments', \@comments);
}

sub add_comment {
    my ($self) = @_;

    $self->validation->required('text');

    my $group = $self->app->schema->resultset("JobGroups")->find($self->param('groupid'));
    return $self->reply->not_found unless $group;

    my $rs = $group->comments->create(
        {
            text    => $self->param('text'),
            user_id => $self->current_user->id,
        });

    $self->emit_event('openqa_user_comment', {id => $rs->id});
    $self->flash('info', 'Comment added');
    return $self->redirect_to('group_overview');
}

sub edit_comment {
    my ($self) = @_;

    $self->validation->required('text');
    $self->validation->required('comment_id');

    my $group = $self->app->schema->resultset("JobGroups")->find($self->param('groupid'));
    return $self->reply->not_found unless $group;

    my $rs = $group->comments->search({id => $self->param("comment_id"), user_id => $self->current_user->id})->update(
        {
            text      => $self->param('text'),
            t_updated => DateTime->now(time_zone => 'floating')
        });

    $self->emit_event('openqa_user_comment', {id => $self->param("comment_id")});
    $self->flash('info', 'Comment changed');
    return $self->redirect_to('group_overview');
}

sub remove_comment {
    my ($self) = @_;

    $self->validation->required('comment_id');

    my $group = $self->app->schema->resultset("JobGroups")->find($self->param('groupid'));
    return $self->reply->not_found unless $group;

    # only admins are allowed to delete comments
    return $self->reply->not_found unless $self->current_user->is_admin;

    my $rs = $group->comments->search(
        {
            id => $self->param("comment_id"),
            user_id => $self->current_user->id
        })->delete();

    $self->emit_event('openqa_user_comment', {id => $self->param("comment_id")});
    $self->flash('info', 'Comment removed');
    return $self->redirect_to('group_overview');
}

1;
# vim: set sw=4 et:
