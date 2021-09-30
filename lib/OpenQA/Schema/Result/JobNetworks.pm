# Copyright 2015 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::JobNetworks;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->table('job_networks');
__PACKAGE__->add_columns(
    name => {
        data_type => 'text',
        is_nullable => 0,
    },
    job_id => {
        data_type => 'integer',
        is_foreign_key => 1,
        is_nullable => 0,
    },
    vlan => {
        data_type => 'integer',
        default_value => undef,
    });

__PACKAGE__->set_primary_key('name', 'job_id');

__PACKAGE__->belongs_to(job => 'OpenQA::Schema::Result::Jobs', 'job_id');

1;
