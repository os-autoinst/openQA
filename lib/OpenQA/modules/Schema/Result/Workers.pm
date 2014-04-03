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

package Schema::Result::Workers;
use base qw/DBIx::Class::Core/;

use db_helpers;

__PACKAGE__->table('workers');
__PACKAGE__->load_components(qw/InflateColumn::DateTime/);
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    host => {
        data_type => 'text',
    },
    instance => {
        data_type => 'integer',
    },
    backend => {
        data_type => 'text',
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
__PACKAGE__->add_unique_constraint(constraint_name => [qw/host instance/]);
__PACKAGE__->has_many(jobs => 'Schema::Result::Jobs', 'worker_id');
__PACKAGE__->has_many(commands => 'Schema::Result::Commands', 'worker_id');

# TODO
# INSERT INTO workers (id, t_created) VALUES(0, datetime('now'));

sub sqlt_deploy_hook {
    my ($self, $sqlt_table) = @_;

    db_helpers::create_auto_timestamps($sqlt_table->schema, __PACKAGE__->table);
}

1;
# vim: set sw=4 et:
