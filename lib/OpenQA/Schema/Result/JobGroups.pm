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
use base qw/DBIx::Class::Core/;
use strict;

__PACKAGE__->table('job_groups');
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
    parent_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 1,
    },
    size_limit_gb => {
        data_type   => 'integer',
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
    });

__PACKAGE__->add_unique_constraint([qw/name/]);

__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->has_many(jobs => 'OpenQA::Schema::Result::Jobs', 'group_id');
__PACKAGE__->has_many(comments => 'OpenQA::Schema::Result::Comments', 'group_id', {order_by => 'id'});
__PACKAGE__->belongs_to(parent => 'OpenQA::Schema::Result::JobGroupParents', 'parent_id', {join_type => 'left', on_delete => 'SET NULL'});

around 'size_limit_gb' => sub {
    my ($orig, $self) = @_;
    return $self->get_column('size_limit_gb') // ($self->parent ? $self->parent->default_size_limit_gb : OpenQA::Schema::JobGroupDefaults::SIZE_LIMIT_GB);
};

around 'keep_logs_in_days' => sub {
    my ($orig, $self) = @_;
    return $self->get_column('keep_logs_in_days') // ($self->parent ? $self->parent->default_keep_logs_in_days : OpenQA::Schema::JobGroupDefaults::KEEP_LOGS_IN_DAYS);
};

around 'keep_important_logs_in_days' => sub {
    my ($orig, $self) = @_;
    return $self->get_column('keep_important_logs_in_days') // ($self->parent ? $self->parent->default_keep_important_logs_in_days : OpenQA::Schema::JobGroupDefaults::KEEP_IMPORTANT_LOGS_IN_DAYS);
};

around 'keep_results_in_days' => sub {
    my ($orig, $self) = @_;
    return $self->get_column('keep_results_in_days') // ($self->parent ? $self->parent->default_keep_results_in_days : OpenQA::Schema::JobGroupDefaults::KEEP_RESULTS_IN_DAYS);
};

around 'keep_important_results_in_days' => sub {
    my ($orig, $self) = @_;
    return $self->get_column('keep_important_results_in_days') // ($self->parent ? $self->parent->default_keep_results_in_days : OpenQA::Schema::JobGroupDefaults::KEEP_IMPORTANT_RESULTS_IN_DAYS);
};

around 'default_priority' => sub {
    my ($orig, $self) = @_;
    return $self->get_column('default_priority') // ($self->parent ? $self->parent->default_priority : OpenQA::Schema::JobGroupDefaults::PRIORITY);
};

1;
