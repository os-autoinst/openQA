# Copyright 2017 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::Bugs;

use strict;
use warnings;

use base 'DBIx::Class::Core';

use Mojo::UserAgent;
use OpenQA::Utils;
use DBIx::Class::Timestamps 'now';

__PACKAGE__->table('bugs');
__PACKAGE__->load_components(qw(InflateColumn::DateTime Timestamps));
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    bugid => {
        data_type => 'text',
    },
    title => {
        data_type => 'text',
        is_nullable => 1,
    },
    priority => {
        data_type => 'text',
        is_nullable => 1,
    },
    assigned => {
        data_type => 'boolean',
        is_nullable => 1,
    },
    assignee => {
        data_type => 'text',
        is_nullable => 1,
    },
    open => {
        data_type => 'boolean',
        is_nullable => 1,
    },
    status => {
        data_type => 'text',
        is_nullable => 1,
    },
    resolution => {
        data_type => 'text',
        is_nullable => 1,
    },
    existing => {
        data_type => 'boolean',
        default_value => 1,
    },
    refreshed => {
        data_type => 'boolean',
        default_value => 0,
    },
);
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint([qw(bugid)]);

1;
