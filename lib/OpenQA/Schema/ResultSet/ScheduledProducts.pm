# Copyright 2023 LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::ResultSet::ScheduledProducts;

use Mojo::Base 'DBIx::Class::ResultSet', -signatures;
use Mojo::JSON qw(encode_json);
use OpenQA::Schema::Result::ScheduledProducts qw(CANCELLED);
use OpenQA::App;

sub create_with_event ($self, $params, $user, $webhook_id = undef) {
    my $scheduled_product = $self->create(
        {
            distri => $params->{DISTRI} // '',
            version => $params->{VERSION} // '',
            flavor => $params->{FLAVOR} // '',
            arch => $params->{ARCH} // '',
            build => $params->{BUILD} // '',
            iso => $params->{ISO} // '',
            settings => $params,
            user_id => $user->id,
            webhook_id => $webhook_id,
        });
    OpenQA::App->singleton->emit_event(openqa_iso_create => {scheduled_product_id => $scheduled_product->id});
    return $scheduled_product;
}

sub cancel_by_webhook_id ($self, $webhook_id, $reason) {
    my $count = 0;
    $count += $_->cancel($reason) for $self->search({webhook_id => $webhook_id, -not => {status => CANCELLED}});
    return {jobs_cancelled => $count};
}

sub update_note ($self, $distri, $version, $flavor, $arch, $build, $note) {
    my $sth = $self->result_source->schema->storage->dbh->prepare(
        <<~'END_SQL'
        UPDATE scheduled_products SET results['note'] = ? where id = (
            SELECT id
            FROM scheduled_products
            WHERE distri = ? and version = ? and flavor = ? and arch = ? and build = ?
            ORDER BY id DESC
            LIMIT 1
        ) RETURNING id;
        END_SQL
    );
    $sth->bind_param(1, encode_json($note));
    $sth->bind_param(2, $distri);
    $sth->bind_param(3, $version);
    $sth->bind_param(4, $flavor);
    $sth->bind_param(5, $arch);
    $sth->bind_param(6, $build);
    $sth->execute;
    return {updated_product_id => $sth->fetchrow_arrayref->[0]};
}

sub job_statistics ($self, $distri, $version, $flavor, $arch, $build) {
    my $sth = $self->result_source->schema->storage->dbh->prepare(
        <<~'END_SQL'
        WITH RECURSIVE
        -- get the initial set of jobs in the scheduled product
        initial_job_ids AS (
            SELECT
                jobs.id AS job_id,
                jobs.scheduled_product_id AS scheduled_product_id
            FROM
                jobs
            WHERE
                jobs.scheduled_product_id in (
                    SELECT
                        max(id)
                    FROM
                        scheduled_products
                    WHERE
                        status in ('new', 'scheduling', 'scheduled') and distri = ? and version = ? and flavor = ? and arch = ? and build = ?
                    GROUP BY
                        arch
                )
        ),
        -- find more recent jobs for each initial job recursively
        latest_id_resolver AS (
            -- start with each job_id from initial_job_ids
            SELECT
                ij.job_id,
                ij.job_id AS latest_job_id,
                ij.scheduled_product_id AS scheduled_product_id,
                1 AS level
            FROM
                initial_job_ids AS ij
            UNION ALL
            -- find the clone_id for the current latest_job_id
            SELECT
                lir.job_id,
                j.clone_id AS latest_job_id,
                lir.scheduled_product_id AS scheduled_product_id,
                lir.level + 1 AS level
            FROM
                jobs AS j
            JOIN latest_id_resolver AS lir ON lir.latest_job_id = j.id
            -- limit the recursion
            WHERE
                lir.level < 50
        ),
        -- filter jobs to only get the latest
        most_recent_jobs AS (
            SELECT DISTINCT ON (job_id)
                job_id as initial_job_id,
                latest_job_id,
                mrj.state as latest_job_state,
                mrj.result as latest_job_result,
                mrj.scheduled_product_id as scheduled_product_id,
                level as chain_length
            FROM
                latest_id_resolver
            JOIN jobs AS mrj ON mrj.id = latest_job_id
            WHERE
                latest_job_id IS NOT NULL
            ORDER BY
                job_id,
                level DESC
        )
        SELECT
            latest_job_state,
            latest_job_result,
            array_agg(latest_job_id) as job_ids,
            array_agg(DISTINCT scheduled_product_id) as scheduled_product_ids
        FROM
            most_recent_jobs
        WHERE
            latest_job_id IS NOT NULL
        GROUP BY
            latest_job_state,
            latest_job_result
        END_SQL
    );
    $sth->bind_param(1, $distri);
    $sth->bind_param(2, $version);
    $sth->bind_param(3, $flavor);
    $sth->bind_param(4, $arch);
    $sth->bind_param(5, $build);
    $sth->execute;
    return $sth->fetchall_hashref([qw(latest_job_state latest_job_result)]);
}

sub delete_expired_entries ($self) {
    # delete all scheduled products without jobs that are older than "scheduled_product_min_storage_duration"
    my $min_storage_duration = OpenQA::App->singleton->config->{misc_limits}->{scheduled_product_min_storage_duration};
    my $sth = $self->result_source->schema->storage->dbh->prepare(
        <<~'END_SQL'
        DELETE FROM scheduled_products
            WHERE
                (t_created < current_date - ?::interval)
                AND (SELECT count(id) FROM jobs WHERE jobs.scheduled_product_id = scheduled_products.id LIMIT 1) = 0
        END_SQL
    );
    $sth->execute("$min_storage_duration days");
}

1;
