# Copyright (C) 2014 SUSE Linux Products GmbH
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

package OpenQA::Schema::Result::JobDependencies;
use base qw/DBIx::Class::Core/;

use db_helpers;

# Use integers instead of a string labels for DEPENDENCIES because:
#  - It's part of the primary key
#  - JobDependencies is an internal table, not exposed in the API
use constant CHAINED => 1;
use constant PARALLEL => 2;
use constant DEPENDENCIES => (CHAINED, PARALLEL);

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
    dependency => { data_type => 'integer' },
);

__PACKAGE__->set_primary_key('child_job_id', 'parent_job_id', 'dependency');

__PACKAGE__->belongs_to( child => 'OpenQA::Schema::Result::Jobs', 'child_job_id' );
__PACKAGE__->belongs_to( parent => 'OpenQA::Schema::Result::Jobs', 'parent_job_id' );

sub sqlt_deploy_hook {
    my ($self, $sqlt_table) = @_;

    $sqlt_table->add_index(name => 'idx_job_dependencies_dependency', fields => ['dependency']);
}

sub to_string {
    my ($self) = @_;

    my %deps = ( 1 => "Chained", 2 => "Parallel" );

    return $deps{$self->dependency};
}

1;
