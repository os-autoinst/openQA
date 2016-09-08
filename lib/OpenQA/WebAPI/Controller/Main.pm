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
    my $jobs = $group->jobs->search({"me.t_created" => $timecond});
    my $builds = $jobs->search(
        {},
        {
            select => ['BUILD', {min => 't_created', -as => 'first_hit'}],
            as     => [qw/BUILD first_hit/],
            order_by => {-desc => 'first_hit'},
            group_by => [qw/BUILD/]});
    my $max_jobs = 0;
    my $buildnr  = 0;
    for my $b (map { $_->BUILD } $builds->all) {
        my $jobs = $self->db->resultset('Jobs')->search(
            {
                'me.BUILD'    => $b,
                'me.group_id' => $group->id,
                'me.clone_id' => undef,
            },
            {order_by => 'me.id DESC'});
        my %jr = (oldest => DateTime->now, passed => 0, failed => 0, inprogress => 0, labeled => 0, softfailed => 0);

        my $count = 0;
        my %seen;
        my @ids = map { $_->id } $jobs->all;
        # prefetch comments to count. Any comment is considered a label here
        # so a build is considered as 'reviewed' if all failures have at least
        # a comment. This could be improved to distinguish between
        # "only-labels", "mixed" and such
        my $c = $self->db->resultset("Comments")->search({job_id => {in => \@ids}});
        my %labels;
        while (my $comment = $c->next) {
            $labels{$comment->job_id}++;
        }
        $jobs->reset;

        while (my $job = $jobs->next) {
            $jr{distri}  //= $job->DISTRI;
            $jr{version} //= $job->VERSION;
            my $key = $job->TEST . "-" . $job->ARCH . "-" . $job->FLAVOR . "-" . $job->MACHINE;
            next if $seen{$key}++;

            $count++;
            $jr{oldest} = $job->t_created if $job->t_created < $jr{oldest};
            if ($job->state eq OpenQA::Schema::Result::Jobs::DONE) {
                if ($job->result eq OpenQA::Schema::Result::Jobs::PASSED) {
                    $jr{passed}++;
                    next;
                }
                if ($job->result eq OpenQA::Schema::Result::Jobs::SOFTFAILED) {
                    $jr{softfailed}++;
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
            my $state = $job->state;
            if (grep { /$state/ } (OpenQA::Schema::Result::Jobs::EXECUTION_STATES)) {
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
    my $only_tagged  = $self->param('only_tagged')  // 0;
    my $group        = $self->db->resultset('JobGroups')->find($self->param('groupid'));
    return $self->reply->not_found unless $group;

    my $res = $self->_group_result($group, $limit_builds);
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
            next if ($build eq '_max');
            next unless $build;
            delete $res->{$build} unless $res->{$build}->{tag};
        }
    }
    $self->stash('result',          $res);
    $self->stash('group',           $group);
    $self->stash('limit_builds',    $limit_builds);
    $self->stash('only_tagged',     $only_tagged);
    $self->stash('comments',        \@comments);
    $self->stash('pinned_comments', \@pinned_comments);
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

1;
# vim: set sw=4 et:
