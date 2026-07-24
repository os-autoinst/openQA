# Copyright 2015 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::JobNextPrevious;

use Mojo::Base 'DBIx::Class::Core', -signatures;

use Moose;
extends 'OpenQA::Schema::Result::Jobs';

__PACKAGE__->table_class('DBIx::Class::ResultSource::View');

# For the time being this is necessary even for virtual views
__PACKAGE__->table('JobNextPrevious');
__PACKAGE__->add_columns(source => {data_type => 'text'});

# do not attempt to deploy() this view
__PACKAGE__->result_source_instance->is_virtual(1);

# Build the "Next & Previous" query SQL. When $isolation_key_count > 0, an
# `EXISTS` clause per history isolation key is folded into the `allofjobs` CTE so
# the whole result (including the "latest" row) is restricted to the isolated
# history. Benchmarks on production (see tasks/096) showed this EXISTS-in-CTE
# form is stable (~2x baseline worst case, no cold-cache cliff) whereas wrapping
# the view with an outer `id IN (subquery)` spiked to several seconds cold.
sub query_sql ($isolation_key_count = 0) {
    my $exists = join '',
      map { "\n            AND EXISTS (SELECT 1 FROM job_settings s WHERE s.job_id=me.id AND s.key=? AND s.value=?)" }
      1 .. $isolation_key_count;
    # with isolation the "latest" row must also respect the isolated history, so
    # it is taken from `allofjobs` (which carries the EXISTS) instead of `jobs`
    my $latest_from = $isolation_key_count ? 'allofjobs' : 'jobs';
    my $latest_where
      = $isolation_key_count
      ? ''
      : 'WHERE DISTRI=? AND VERSION=? AND FLAVOR=? AND ARCH=? AND TEST=? AND MACHINE=? ';
    return <<~"END_SQL";
        WITH allofjobs AS(
            SELECT me.* FROM jobs me
                WHERE me.state=?
                    AND me.result NOT IN (?, ?, ?, ?, ?, ?)
                    AND me.DISTRI=? AND me.VERSION=? AND me.FLAVOR=? AND me.ARCH=?
                    AND me.TEST=? AND me.MACHINE=?$exists
        )
        ((SELECT *, 'l' AS source FROM $latest_from
            ${latest_where}ORDER BY ID DESC LIMIT 1)
        UNION (SELECT *, 'n' AS source FROM allofjobs WHERE id > ? ORDER BY ID ASC LIMIT ? + 1)
        UNION (SELECT *, 'p' AS source FROM allofjobs WHERE id < ? ORDER BY ID DESC LIMIT ? + 1)
        UNION (SELECT *, 'c' AS source FROM jobs WHERE id = ?)
        ORDER BY ID DESC)
        END_SQL
}

__PACKAGE__->result_source_instance->view_definition(query_sql());

1;
