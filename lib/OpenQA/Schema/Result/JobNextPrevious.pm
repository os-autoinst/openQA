# Copyright 2015 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

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
