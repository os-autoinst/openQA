# Copyright 2017 SUSE LLC
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

package OpenQA::Schema::Result::Bugs;

use strict;
use warnings;

use base 'DBIx::Class::Core';

use Mojo::UserAgent;
use OpenQA::Utils;
use DBIx::Class::Timestamps 'now';

__PACKAGE__->table('bugs');
__PACKAGE__->load_components(qw(InflateColumn::DateTime Timestamps));
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    bugid => {
        data_type => 'text',
    },
    title => {
        data_type   => 'text',
        is_nullable => 1,
    },
    priority => {
        data_type   => 'text',
        is_nullable => 1,
    },
    assigned => {
        data_type   => 'boolean',
        is_nullable => 1,
    },
    assignee => {
        data_type   => 'text',
        is_nullable => 1,
    },
    open => {
        data_type   => 'boolean',
        is_nullable => 1,
    },
    status => {
        data_type   => 'text',
        is_nullable => 1,
    },
    resolution => {
        data_type   => 'text',
        is_nullable => 1,
    },
    existing => {
        data_type     => 'boolean',
        default_value => 1,
    },
    refreshed => {
        data_type     => 'boolean',
        default_value => 0,
    },
);
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint([qw(bugid)]);

1;
