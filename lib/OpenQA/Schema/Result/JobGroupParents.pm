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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package OpenQA::Schema::Result::JobGroupParents;
use OpenQA::Schema::JobGroupDefaults;
use Class::Method::Modifiers;
use base qw/DBIx::Class::Core/;
use strict;

__PACKAGE__->table('job_group_parents');
__PACKAGE__->load_components(qw/Timestamps/);

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    name => {
        data_type   => 'text',
        is_nullable => 0,
    },
    default_size_limit_gb => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    default_keep_logs_in_days => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    default_keep_important_logs_in_days => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    default_keep_results_in_days => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    default_keep_important_results_in_days => {
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
    });

__PACKAGE__->add_unique_constraint([qw/name/]);

__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->has_many(children => 'OpenQA::Schema::Result::JobGroups', 'parent_id', {order_by => [{-asc => 'sort_order'}, {-asc => 'name'}]});

around 'default_size_limit_gb' => sub {
    my ($orig, $self) = @_;
    return $self->get_column('default_size_limit_gb') // OpenQA::Schema::JobGroupDefaults::SIZE_LIMIT_GB;
};

around 'default_keep_logs_in_days' => sub {
    my ($orig, $self) = @_;
    return $self->get_column('default_keep_logs_in_days') // OpenQA::Schema::JobGroupDefaults::KEEP_LOGS_IN_DAYS;
};

around 'default_keep_important_logs_in_days' => sub {
    my ($orig, $self) = @_;
    return $self->get_column('default_keep_important_logs_in_days') // OpenQA::Schema::JobGroupDefaults::KEEP_IMPORTANT_LOGS_IN_DAYS;
};

around 'default_keep_results_in_days' => sub {
    my ($orig, $self) = @_;
    return $self->get_column('default_keep_results_in_days') // OpenQA::Schema::JobGroupDefaults::KEEP_RESULTS_IN_DAYS;
};

around 'default_keep_important_results_in_days' => sub {
    my ($orig, $self) = @_;
    return $self->get_column('default_keep_important_results_in_days') // OpenQA::Schema::JobGroupDefaults::KEEP_IMPORTANT_RESULTS_IN_DAYS;
};

around 'default_priority' => sub {
    my ($orig, $self) = @_;
    return $self->get_column('default_priority') // OpenQA::Schema::JobGroupDefaults::PRIORITY;
};

sub child_group_ids {
    my ($self) = @_;
    return [map { $_->id } $self->children];
}

sub jobs {
    my ($self) = @_;

    return $self->result_source->schema->resultset('Jobs')->search(
        {
            group_id => {in => $self->child_group_ids}});
}

sub rendered_description {
    my ($self) = @_;

    return unless $self->description;
    my $m = CommentsMarkdownParser->new;
    return Mojo::ByteStream->new($m->markdown($self->description));
}

sub tags {
    my ($self) = @_;

    # for now
    return {};
}

1;
