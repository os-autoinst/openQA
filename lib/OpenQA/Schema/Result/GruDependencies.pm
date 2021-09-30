# Copyright 2015 SUSE LLC
# Copyright 2015 Red Hat
# SPDX-License-Identifier: GPL-2.0-or-later

# Entries in this table are transient; when a job that depends on a
# gru task is created a row should be added here, when the task
# completes, the entry will be deleted.

package OpenQA::Schema::Result::GruDependencies;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->table('gru_dependencies');
__PACKAGE__->add_columns(
    job_id => {
        data_type => 'integer',
        is_foreign_key => 1,
    },
    gru_task_id => {
        data_type => 'integer',
        is_foreign_key => 1,
    },
);

__PACKAGE__->set_primary_key('job_id', 'gru_task_id');

__PACKAGE__->belongs_to(job => 'OpenQA::Schema::Result::Jobs', 'job_id');
__PACKAGE__->belongs_to(gru_task => 'OpenQA::Schema::Result::GruTasks', 'gru_task_id');

1;
