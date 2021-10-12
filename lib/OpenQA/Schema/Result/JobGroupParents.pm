# Copyright 2016-2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::JobGroupParents;

use strict;
use warnings;

use base 'DBIx::Class::Core';

use OpenQA::App;
use OpenQA::Markdown 'markdown_to_html';
use OpenQA::JobGroupDefaults;
use OpenQA::Utils 'parse_tags_from_comments';
use Class::Method::Modifiers;

__PACKAGE__->table('job_group_parents');
__PACKAGE__->load_components(qw(Timestamps));

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    name => {
        data_type => 'text',
        is_nullable => 0,
    },
    size_limit_gb => {
        data_type => 'integer',
        is_nullable => 1,
    },
    exclusively_kept_asset_size => {
        data_type => 'bigint',
        is_nullable => 1,
    },
    default_keep_logs_in_days => {
        data_type => 'integer',
        is_nullable => 1,
    },
    default_keep_important_logs_in_days => {
        data_type => 'integer',
        is_nullable => 1,
    },
    default_keep_results_in_days => {
        data_type => 'integer',
        is_nullable => 1,
    },
    default_keep_important_results_in_days => {
        data_type => 'integer',
        is_nullable => 1,
    },
    default_priority => {
        data_type => 'integer',
        is_nullable => 1,
    },
    sort_order => {
        data_type => 'integer',
        is_nullable => 1,
    },
    description => {
        data_type => 'text',
        is_nullable => 1,
    },
    build_version_sort => {
        data_type => 'boolean',
        default_value => 1,
        is_nullable => 0,
    },
    carry_over_bugrefs => {
        data_type => 'boolean',
        is_nullable => 1,
    });

__PACKAGE__->add_unique_constraint([qw(name)]);

__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->has_many(
    children => 'OpenQA::Schema::Result::JobGroups',
    'parent_id', {order_by => [{-asc => 'sort_order'}, {-asc => 'name'}]});
__PACKAGE__->has_many(comments => 'OpenQA::Schema::Result::Comments', 'parent_group_id', {order_by => 'id'});

sub _get_column_or_default {
    my ($self, $column, $setting) = @_;

    if (defined(my $own_value = $self->get_column($column))) {
        return $own_value;
    }
    return OpenQA::App->singleton->config->{default_group_limits}->{$setting};
}

around 'default_keep_logs_in_days' => sub {
    my ($orig, $self) = @_;
    return $self->_get_column_or_default('default_keep_logs_in_days', 'log_storage_duration');
};

around 'default_keep_important_logs_in_days' => sub {
    my ($orig, $self) = @_;
    return $self->_get_column_or_default('default_keep_important_logs_in_days', 'important_log_storage_duration');
};

around 'default_keep_results_in_days' => sub {
    my ($orig, $self) = @_;
    return $self->_get_column_or_default('default_keep_results_in_days', 'result_storage_duration');
};

around 'default_keep_important_results_in_days' => sub {
    my ($orig, $self) = @_;
    return $self->_get_column_or_default('default_keep_important_results_in_days', 'important_result_storage_duration');
};

around 'default_priority' => sub {
    my ($orig, $self) = @_;
    return $self->get_column('default_priority') // OpenQA::JobGroupDefaults::PRIORITY;
};

around 'carry_over_bugrefs' => sub {
    my ($orig, $self) = @_;
    return $self->get_column('carry_over_bugrefs') // OpenQA::JobGroupDefaults::CARRY_OVER_BUGREFS;
};

sub matches_nested {
    my ($self, $regex) = @_;

    return 1 if ($self->name =~ /$regex/);
    my $children = $self->children;
    while (my $child = $children->next) {
        return 1 if ($child->matches_nested($regex));
    }
    return 0;
}

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
    my $self = shift;
    return undef unless my $desc = $self->description;
    return Mojo::ByteStream->new(markdown_to_html($desc));
}

sub tags {
    my ($self) = @_;

    my %res;
    parse_tags_from_comments($self, \%res);
    for my $child ($self->children) {
        parse_tags_from_comments($child, \%res);
    }
    return \%res;
}

1;
