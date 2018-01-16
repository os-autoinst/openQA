# Copyright (C) 2015 SUSE Linux Products GmbH
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

package OpenQA::Schema::Result::JobGroups;
use OpenQA::Schema::JobGroupDefaults;
use Class::Method::Modifiers;
use base 'DBIx::Class::Core';
use OpenQA::Utils 'log_debug';
use Date::Format 'time2str';
use strict;

__PACKAGE__->table('job_groups');
__PACKAGE__->load_components(qw(Timestamps));

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    name => {
        data_type   => 'text',
        is_nullable => 0,
    },
    parent_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 1,
    },
    size_limit_gb => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    exclusively_kept_asset_size => {
        data_type   => 'bigint',
        is_nullable => 1,
    },
    keep_logs_in_days => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    keep_important_logs_in_days => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    keep_results_in_days => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    keep_important_results_in_days => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    default_priority => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    sort_order => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    description => {
        data_type   => 'text',
        is_nullable => 1,
    },
    build_version_sort => {
        data_type     => 'boolean',
        default_value => 1,
        is_nullable   => 0,
    });

__PACKAGE__->add_unique_constraint([qw(name parent_id)]);

__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->has_many(jobs => 'OpenQA::Schema::Result::Jobs', 'group_id');
__PACKAGE__->has_many(comments => 'OpenQA::Schema::Result::Comments', 'group_id', {order_by => 'id'});
__PACKAGE__->belongs_to(
    parent => 'OpenQA::Schema::Result::JobGroupParents',
    'parent_id', {join_type => 'left', on_delete => 'SET NULL'});

around 'size_limit_gb' => sub {
    my ($orig, $self) = @_;
    return $self->get_column('size_limit_gb')
      // ($self->parent ? $self->parent->default_size_limit_gb : OpenQA::Schema::JobGroupDefaults::SIZE_LIMIT_GB);
};

around 'keep_logs_in_days' => sub {
    my ($orig, $self) = @_;
    return $self->get_column('keep_logs_in_days')
      // (
        $self->parent ? $self->parent->default_keep_logs_in_days : OpenQA::Schema::JobGroupDefaults::KEEP_LOGS_IN_DAYS);
};

around 'keep_important_logs_in_days' => sub {
    my ($orig, $self) = @_;
    return $self->get_column('keep_important_logs_in_days') // (
        $self->parent ?
          $self->parent->default_keep_important_logs_in_days
        : OpenQA::Schema::JobGroupDefaults::KEEP_IMPORTANT_LOGS_IN_DAYS
    );
};

around 'keep_results_in_days' => sub {
    my ($orig, $self) = @_;
    return $self->get_column('keep_results_in_days') // (
        $self->parent ?
          $self->parent->default_keep_results_in_days
        : OpenQA::Schema::JobGroupDefaults::KEEP_RESULTS_IN_DAYS
    );
};

around 'keep_important_results_in_days' => sub {
    my ($orig, $self) = @_;
    return $self->get_column('keep_important_results_in_days') // (
        $self->parent ?
          $self->parent->default_keep_important_results_in_days
        : OpenQA::Schema::JobGroupDefaults::KEEP_IMPORTANT_RESULTS_IN_DAYS
    );
};

around 'default_priority' => sub {
    my ($orig, $self) = @_;
    return $self->get_column('default_priority')
      // ($self->parent ? $self->parent->default_priority : OpenQA::Schema::JobGroupDefaults::PRIORITY);
};

sub rendered_description {
    my ($self) = @_;

    if ($self->description) {
        my $m = CommentsMarkdownParser->new;
        return Mojo::ByteStream->new($m->markdown($self->description));
    }
    return;
}

sub full_name {
    my ($self) = @_;

    if (my $parent = $self->parent) {
        return $parent->name . ' / ' . $self->name;
    }
    return $self->name;
}

sub matches_nested {
    my ($self, $regex) = @_;
    return $self->full_name =~ /$regex/;
}

# check the group comments for important builds
sub important_builds {
    my ($self) = @_;

    my %importants;
    my $comments = $self->comments;
    while (my $comment = $comments->next) {
        my @tag = $comment->tag;
        next unless $tag[0];
        if ($tag[1] eq 'important') {
            $importants{$tag[0]} = 1;
        }
        elsif ($tag[1] eq '-important') {
            delete $importants{$tag[0]};
        }
    }
    return [sort keys %importants];
}

sub _find_expired_jobs {
    my ($self, $important_builds, $keep_in_days, $keep_important_in_days) = @_;

    my @ors;

    # 0 means forever
    return [] unless $keep_in_days;

    # all jobs not in important builds that are expired
    my $timecond = {'<' => time2str('%Y-%m-%d %H:%M:%S', time - 24 * 3600 * $keep_in_days, 'UTC')};

    # filter out linked jobs
    my $expired_jobs
      = $self->jobs->search(
        {BUILD => {-not_in => $important_builds}, t_finished => $timecond, text => {like => 'label:linked%'}},
        {order_by => 'me.id', join => 'comments'});
    my @linked_jobs = map { $_->id } $expired_jobs->all;
    push(@ors, {BUILD => {-not_in => $important_builds}, t_finished => $timecond, id => {-not_in => \@linked_jobs}});

    if ($keep_important_in_days) {
        # expired jobs in important builds
        my $timecond = {'<' => time2str('%Y-%m-%d %H:%M:%S', time - 24 * 3600 * $keep_important_in_days, 'UTC')};
        push(@ors,
            {-or => [{BUILD => {-in => $important_builds}}, {id => {-in => \@linked_jobs}}], t_finished => $timecond},
        );
    }
    return $self->jobs->search({-or => \@ors}, {order_by => qw(id)});
}

sub find_jobs_with_expired_results {
    my ($self, $important_builds) = @_;

    $important_builds //= $self->important_builds;
    return [
        $self->_find_expired_jobs(
            $important_builds, $self->keep_results_in_days, $self->keep_important_results_in_days
        )->all
    ];
}

sub find_jobs_with_expired_logs {
    my ($self, $important_builds) = @_;

    $important_builds //= $self->important_builds;
    return [$self->_find_expired_jobs($important_builds, $self->keep_logs_in_days, $self->keep_important_logs_in_days)
          ->search({logs_present => 1})->all
    ];
}

# gru task, added when scheduling new iso
sub limit_results_and_logs {
    my ($app) = @_;

    my $groups = $app->db->resultset('JobGroups');
    while (my $group = $groups->next) {
        my $important_builds = $group->important_builds;
        for my $job (@{$group->find_jobs_with_expired_results($important_builds)}) {
            $job->delete;
        }
        for my $job (@{$group->find_jobs_with_expired_logs($important_builds)}) {
            $job->delete_logs;
        }
    }
}

# parse comments and list the all builds mentioned
sub tags {
    my ($self) = @_;

    my %res;
    for my $comment ($self->comments) {
        my @tag   = $comment->tag;
        my $build = $tag[0];
        next unless $build;

        my $version = $tag[3];
        my $tag_id = $version ? "$version-$build" : $build;

        log_debug('Tag found on build ' . $build . ' of type ' . $tag[1]);
        log_debug('description: ' . $tag[2]) if $tag[2];
        if ($tag[1] eq '-important') {
            log_debug('Deleting tag on build ' . $build);
            delete $res{$tag_id};
            next;
        }

        # ignore tags on non-existing builds
        $res{$tag_id} = {build => $build, type => $tag[1], description => $tag[2], version => $version};
    }

    return \%res;
}

1;
