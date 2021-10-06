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

package OpenQA::Schema::Result::JobNetworks;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->table('job_networks');
__PACKAGE__->add_columns(
    name => {
        data_type   => 'text',
        is_nullable => 0,
    },
    job_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 0,
    },
    vlan => {
        data_type     => 'integer',
        default_value => undef,
    });

__PACKAGE__->set_primary_key('name', 'job_id');

__PACKAGE__->belongs_to(job => 'OpenQA::Schema::Result::Jobs', 'job_id');

1;
