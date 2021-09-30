# Copyright 2014 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::Machines;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->table('machines');
__PACKAGE__->load_components(qw(Timestamps));
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    name => {
        data_type => 'text',
    },
    backend => {
        data_type => 'text',
    },
    description => {
        data_type => 'text',
        is_nullable => 1,
    },
);
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint([qw(name)]);
__PACKAGE__->has_many(job_templates => 'OpenQA::Schema::Result::JobTemplates', 'machine_id');
__PACKAGE__->has_many(
    settings => 'OpenQA::Schema::Result::MachineSettings',
    'machine_id', {order_by => {-asc => 'key'}});

1;
