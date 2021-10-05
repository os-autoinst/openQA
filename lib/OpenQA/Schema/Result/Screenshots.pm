# Copyright 2016-2019 SUSE LLC
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

package OpenQA::Schema::Result::Screenshots;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->table('screenshots');
__PACKAGE__->load_components(qw(InflateColumn::DateTime));

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    filename => {
        data_type   => 'text',
        is_nullable => 0,
    },
    # we don't care for t_updated, so just add t_created
    t_created => {
        data_type   => 'timestamp',
        is_nullable => 0,
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint([qw(filename)]);
__PACKAGE__->has_many(
    links => 'OpenQA::Schema::Result::ScreenshotLinks',
    'screenshot_id',
    {cascade_delete => 0});
__PACKAGE__->has_many(
    links_outer => 'OpenQA::Schema::Result::ScreenshotLinks',
    'screenshot_id',
    {join_type => 'left outer', cascade_delete => 0});

1;
