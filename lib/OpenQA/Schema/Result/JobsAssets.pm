# Copyright 2014 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::JobsAssets;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->table('jobs_assets');
__PACKAGE__->load_components(qw(Timestamps));
__PACKAGE__->add_columns(
    job_id => {
        data_type => 'integer',
        is_foreign_key => 1,
    },
    asset_id => {
        data_type => 'integer',
        is_foreign_key => 1,
    },
    created_by => {
        data_type => 'boolean',
        default_value => '0',
    });
__PACKAGE__->add_timestamps;

__PACKAGE__->add_unique_constraint([qw(job_id asset_id)]);

__PACKAGE__->belongs_to(job => 'OpenQA::Schema::Result::Jobs', 'job_id');
__PACKAGE__->belongs_to(asset => 'OpenQA::Schema::Result::Assets', 'asset_id');

1;
