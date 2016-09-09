# Copyright (C) 2015 SUSE Linux Products GmbH
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
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::Schema::Result::JobGroupSubscriptions;
use base qw/DBIx::Class::Core/;
use strict;

__PACKAGE__->load_components(qw/Core/);
__PACKAGE__->load_components(qw/InflateColumn::DateTime Timestamps/);
__PACKAGE__->table('jobgroupsubscriptions');
__PACKAGE__->add_columns(
    group_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
    },
    user_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
    },
    flags => {
        data_type     => 'integer',
        is_nullable   => 1,
        default_value => '0',
    },
);

__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('group_id', 'user_id');

#__PACKAGE__->belongs_to(user => 'OpenQA::Schema::Result::Users', 'user_id');

__PACKAGE__->belongs_to(
    'user',
    'OpenQA::Schema::Result::Users',
    {'foreign.id' => "self.user_id"},
    {
        is_deferrable => 1,
        join_type     => "LEFT",
        on_delete     => "CASCADE",
        on_update     => "CASCADE",
    },
);

__PACKAGE__->belongs_to(
    'group',
    'OpenQA::Schema::Result::JobGroups',
    {'foreign.id' => "self.group_id"},
    {
        is_deferrable => 1,
        join_type     => "LEFT",
        on_delete     => "CASCADE",
        on_update     => "CASCADE",
    },
);

# Flags
use constant {
    NONE                => 0,
    MAIL_ON_NEW_COMMENT => 1
};

1;
