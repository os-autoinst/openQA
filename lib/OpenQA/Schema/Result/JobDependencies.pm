# Copyright 2014 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::JobDependencies;

use strict;
use warnings;

use base 'DBIx::Class::Core';

use OpenQA::JobDependencies::Constants;

__PACKAGE__->table('job_dependencies');
__PACKAGE__->add_columns(
    child_job_id => {
        data_type => 'integer',
        is_foreign_key => 1,
    },
    parent_job_id => {
        data_type => 'integer',
        is_foreign_key => 1,
    },
    dependency => {data_type => 'integer'},
);

__PACKAGE__->set_primary_key('child_job_id', 'parent_job_id', 'dependency');

__PACKAGE__->belongs_to(child => 'OpenQA::Schema::Result::Jobs', 'child_job_id');
__PACKAGE__->belongs_to(parent => 'OpenQA::Schema::Result::Jobs', 'parent_job_id');

sub sqlt_deploy_hook {
    my ($self, $sqlt_table) = @_;

    $sqlt_table->add_index(name => 'idx_job_dependencies_dependency', fields => ['dependency']);
}

sub to_string {
    my ($self) = @_;
    return OpenQA::JobDependencies::Constants::display_name($self->dependency);
}

1;
