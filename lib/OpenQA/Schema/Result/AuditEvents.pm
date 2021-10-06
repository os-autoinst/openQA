# Copyright 2015 SUSE LLC
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

package OpenQA::Schema::Result::AuditEvents;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->table('audit_events');
__PACKAGE__->load_components(qw(Timestamps));
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    user_id => {
        data_type   => 'integer',
        is_nullable => 1
    },
    connection_id => {
        data_type   => 'text',
        is_nullable => 1
    },
    event => {
        data_type   => 'text',
        is_nullable => 0
    },
    event_data => {
        data_type   => 'text',
        is_nullable => 1
    });
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->belongs_to(owner => 'OpenQA::Schema::Result::Users', 'user_id', {join_type => 'left'});

1;
