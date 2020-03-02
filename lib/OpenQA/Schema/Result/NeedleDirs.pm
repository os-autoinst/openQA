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

package OpenQA::Schema::Result::NeedleDirs;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->table('needle_dirs');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    path => {
        data_type   => 'text',
        is_nullable => 0
    },
    name => {
        data_type => 'text'
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint([qw(path)]);

__PACKAGE__->has_many(needles => 'OpenQA::Schema::Result::Needles', 'dir_id');

sub set_name_from_job {
    my ($self, $job) = @_;

    $self->name(sprintf('%s-%s', $job->DISTRI, $job->VERSION));
}

1;
