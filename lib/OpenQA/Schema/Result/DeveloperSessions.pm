# Copyright (C) 2018 SUSE LLC
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

package OpenQA::Schema::Result::DeveloperSessions;

use strict;
use warnings;

use base 'DBIx::Class::Core';

use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use Date::Format;
use Try::Tiny;

__PACKAGE__->table('developer_sessions');
__PACKAGE__->load_components(qw(Timestamps));
__PACKAGE__->add_columns(
    job_id => {
        data_type      => 'integer',
        is_nullable    => 0,
        is_foreign_key => 1,
    },
    user_id => {
        data_type      => 'integer',
        is_nullable    => 0,
        is_foreign_key => 1,
    },
    ws_connection_count => {
        data_type     => 'integer',
        default_value => 0,
    });
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('job_id');
__PACKAGE__->belongs_to(
    job => 'OpenQA::Schema::Result::Jobs',
    'job_id',
    {join_type => 'left'});
__PACKAGE__->belongs_to(
    user => 'OpenQA::Schema::Result::Users',
    'user_id',
    {join_type => 'left'});

1;
