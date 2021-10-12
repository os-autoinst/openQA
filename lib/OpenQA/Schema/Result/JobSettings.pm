# Copyright 2014 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::JobSettings;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->table('job_settings');
__PACKAGE__->load_components(qw(InflateColumn::DateTime Timestamps));
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    key => {
        data_type => 'text',
    },
    value => {
        data_type => 'text',
    },
    job_id => {
        data_type => 'integer',
        is_foreign_key => 1,
    },
);
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->belongs_to(
    job => "OpenQA::Schema::Result::Jobs",
    {'foreign.id' => "self.job_id"},
    {
        is_deferrable => 1,
        join_type => "LEFT",
        on_delete => "CASCADE",
        on_update => "CASCADE",
    },
);
__PACKAGE__->has_many(
    siblings => "OpenQA::Schema::Result::JobSettings",
    {"foreign.job_id" => "self.job_id"});

sub sqlt_deploy_hook {
    my ($self, $sqlt_table) = @_;
    $sqlt_table->add_index(name => 'idx_value_settings', fields => ['key', 'value']);
    $sqlt_table->add_index(name => 'idx_job_id_value_settings', fields => ['job_id', 'key', 'value']);
}

1;
