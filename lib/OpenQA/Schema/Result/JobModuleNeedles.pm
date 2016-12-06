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
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::Schema::Result::JobModuleNeedles;
use base 'DBIx::Class::Core';
use strict;

__PACKAGE__->table('job_module_needles');

__PACKAGE__->add_columns(
    needle_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    job_module_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    matched => {
        data_type     => 'boolean',
        default_value => 1
    });

__PACKAGE__->add_unique_constraint([qw(needle_id job_module_id)]);

__PACKAGE__->belongs_to(job_module => 'OpenQA::Schema::Result::JobModules', 'job_module_id');
__PACKAGE__->belongs_to(needle     => 'OpenQA::Schema::Result::Needles',    'needle_id');

1;
