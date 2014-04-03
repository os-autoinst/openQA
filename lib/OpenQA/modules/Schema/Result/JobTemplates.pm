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

package Schema::Result::JobTemplates;
use base qw/DBIx::Class::Core/;

use db_helpers;

__PACKAGE__->table('job_templates');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    product_id => {
        data_type => 'integer',
    },
    machine_id => {
        data_type => 'integer',
    },
    test_suite_id => {
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
__PACKAGE__->belongs_to(product => 'Schema::Result::Products', 'product_id');
__PACKAGE__->belongs_to(machine => 'Schema::Result::Machines', 'machine_id');
__PACKAGE__->belongs_to(test_suite => 'Schema::Result::TestSuites', 'test_suite_id');
__PACKAGE__->add_unique_constraint([ qw/product_id machine_id test_suite_id/ ]);

sub sqlt_deploy_hook {
    my ($self, $sqlt_table) = @_;

    db_helpers::create_auto_timestamps($sqlt_table->schema, __PACKAGE__->table);
}

sub variables {
    my $self = shift;

    $self->machine->variables.$self->test_suite->variables.$self->product->variables;
}

1;
