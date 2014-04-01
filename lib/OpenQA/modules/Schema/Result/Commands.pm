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

package Schema::Result::Commands;
use base qw/DBIx::Class::Core/;

use db_helpers;

__PACKAGE__->table('commands');
__PACKAGE__->load_components(qw/InflateColumn::DateTime/);
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    command => {
        data_type => 'text',
    },
    t_processed => {
        data_type => 'timestamp',
        is_nullable => 1
    },
    worker_id => {
        data_type => 'integer',
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
__PACKAGE__->belongs_to(worker => 'Schema::Result::Workers', 'worker_id');

sub sqlt_deploy_hook {
    my ($self, $sqlt_table) = @_;

    db_helpers::create_auto_timestamps($sqlt_table->schema, __PACKAGE__->table);
}

1;
# Local Variables:
# mode: cperl
# cperl-close-paren-offset: -4
# cperl-continued-statement-offset: 4
# cperl-indent-level: 4
# cperl-indent-parens-as-block: t
# cperl-tab-always-indent: t
# indent-tabs-mode: nil
# End:
# vim: set ts=4 sw=4 sts=4 et:
