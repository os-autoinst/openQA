# Copyright (C) 2015 SUSE LLC
# Copyright (C) 2015 Red Hat
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

# Entries in this table are transient; when a job that depends on a
# gru task is created a row should be added here, when the task
# completes, the entry will be deleted.

package OpenQA::Schema::Result::GruDependencies;
use base qw(DBIx::Class::Core);
use strict;

use db_helpers;

__PACKAGE__->table('gru_dependencies');
__PACKAGE__->add_columns(
    job_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
    },
    gru_task_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
    },
);

__PACKAGE__->set_primary_key('job_id', 'gru_task_id');

__PACKAGE__->belongs_to(job      => 'OpenQA::Schema::Result::Jobs',     'job_id');
__PACKAGE__->belongs_to(gru_task => 'OpenQA::Schema::Result::GruTasks', 'gru_task_id');

1;
