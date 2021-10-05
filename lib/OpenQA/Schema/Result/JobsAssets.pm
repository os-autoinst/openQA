# Copyright 2014 SUSE LLC
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

package OpenQA::Schema::Result::JobsAssets;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->table('jobs_assets');
__PACKAGE__->load_components(qw(Timestamps));
__PACKAGE__->add_columns(
    job_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
    },
    asset_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
    },
    created_by => {
        data_type     => 'boolean',
        default_value => '0',
    });
__PACKAGE__->add_timestamps;

__PACKAGE__->add_unique_constraint([qw(job_id asset_id)]);

__PACKAGE__->belongs_to(job   => 'OpenQA::Schema::Result::Jobs',   'job_id');
__PACKAGE__->belongs_to(asset => 'OpenQA::Schema::Result::Assets', 'asset_id');

1;
