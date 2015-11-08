# Copyright (C) 2015 SUSE LLC
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

package OpenQA::Schema::Result::Needles;
use base qw/DBIx::Class::Core/;

use db_helpers;

__PACKAGE__->table('needles');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    filename => {
        data_type => 'text',
    },
    first_seen_module_id => {
        data_type => 'integer',
    },
    last_seen_module_id => {
        data_type => 'integer',
    },
    last_matched_module_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint([qw/filename/]);
__PACKAGE__->belongs_to(first_seen => 'OpenQA::Schema::Result::JobModules', 'first_seen_module_id');
__PACKAGE__->belongs_to(last_seen  => 'OpenQA::Schema::Result::JobModules', 'last_seen_module_id');
__PACKAGE__->belongs_to(last_match => 'OpenQA::Schema::Result::JobModules', 'last_matched_module_id');

sub update_needle($$$) {
    my ($filename, $module_id, $matched) = @_;

    my $schema = OpenQA::Scheduler::Scheduler::schema();
    my $guard  = $schema->txn_scope_guard;

    my $needle = $schema->resultset('Needles')->find({filename => $filename}, {key => 'needles_filename'});
    if (!$needle) {
        $needle->first_seen_module_id = $module_id;
    }
    # it's not impossible that two instances update this information independent of each other, but we don't mind
    # the *exact* last module as long as it's alive around the same time
    $needle->last_seen_module_id = $module_id;
    if ($matched) {
        $needle->last_matched_module_id = $module_id;
    }
    if ($needle->in_storage) {
        $needle->insert;
    }
    else {
        $needle->update;
    }
    $guard->commit;
}

1;
