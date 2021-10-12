# Copyright 2014 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::TestSuiteSettings;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->table('test_suite_settings');
__PACKAGE__->load_components(qw(Timestamps));
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    test_suite_id => {
        data_type => 'integer',
        is_foreign_key => 1,
    },
    key => {
        data_type => 'text',
    },
    value => {
        data_type => 'text',
    },
);
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint([qw(test_suite_id key)]);

__PACKAGE__->belongs_to(
    "test_suite",
    "OpenQA::Schema::Result::TestSuites",
    {'foreign.id' => "self.test_suite_id"},
    {
        is_deferrable => 1,
        join_type => "LEFT",
        on_delete => "CASCADE",
        on_update => "CASCADE",
    },
);

1;
