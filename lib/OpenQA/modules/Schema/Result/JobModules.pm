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

package Schema::Result::JobModules;
use base qw/DBIx::Class::Core/;

use db_helpers;

__PACKAGE__->table('job_modules');
__PACKAGE__->load_components(qw/InflateColumn::DateTime/);
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    job_id => {
        data_type => 'integer',
        is_foreign_key => 1,
      },
    name => {
      data_type => 'text',
    },
    script => {
      data_type => 'text',
    },
    category => {
      data_type => 'text',
    },
    result_id => {
        data_type => 'integer',
        default_value => 0,
        is_foreign_key => 1,
    },
    t_created => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
    t_updated => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->belongs_to(
    "job",
    "Schema::Result::Jobs",
    { 'foreign.id' => "self.job_id" },
    {
        is_deferrable => 1,
        join_type     => "LEFT",
        on_delete     => "CASCADE",
        on_update     => "CASCADE",
    },
  );
__PACKAGE__->belongs_to(result => 'Schema::Result::JobResults', 'result_id');


sub sqlt_deploy_hook {
    my ($self, $sqlt_table) = @_;

    db_helpers::create_auto_timestamps($sqlt_table->schema, __PACKAGE__->table);
}

1;
# vim: set sw=4 et:
