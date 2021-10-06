# Copyright 2016 SUSE LLC
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

package OpenQA::Schema::Result::ScreenshotLinks;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->table('screenshot_links');

__PACKAGE__->add_columns(
    screenshot_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    job_id => {
        data_type   => 'integer',
        is_nullable => 0,
    });

__PACKAGE__->belongs_to(job        => 'OpenQA::Schema::Result::Jobs',        'job_id');
__PACKAGE__->belongs_to(screenshot => 'OpenQA::Schema::Result::Screenshots', 'screenshot_id');

1;
