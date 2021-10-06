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

package OpenQA::Schema::Result::JobNextPrevious;

use strict;
use warnings;

use base 'DBIx::Class::Core';

use Moose;
extends 'OpenQA::Schema::Result::Jobs';

__PACKAGE__->table_class('DBIx::Class::ResultSource::View');

# For the time being this is necessary even for virtual views
__PACKAGE__->table('JobNextPrevious');

# do not attempt to deploy() this view
__PACKAGE__->result_source_instance->is_virtual(1);

__PACKAGE__->result_source_instance->view_definition(
    q[
    WITH allofjobs AS(
    SELECT me.*
    FROM jobs me WHERE me.state=?
    AND me.result NOT IN (?, ?, ?, ?, ?, ?)
    AND me.DISTRI=? AND me.VERSION=? AND me.FLAVOR=? AND me.ARCH=?
    AND me.TEST=? AND me.MACHINE=?
    )
    (SELECT *
    FROM jobs
    WHERE DISTRI=? AND VERSION=? AND FLAVOR=? AND ARCH=? AND TEST=? AND MACHINE=?
    ORDER BY ID DESC
    LIMIT 1)
    UNION
    (SELECT *
    FROM allofjobs
    WHERE id > ?
    ORDER BY ID ASC
    LIMIT ?)
    UNION
    (SELECT *
    FROM allofjobs
    WHERE id < ?
    ORDER BY ID DESC
    LIMIT ?)
    UNION
    (SELECT *
    FROM jobs
    WHERE id = ?)
    ORDER BY ID DESC]
);

1;
