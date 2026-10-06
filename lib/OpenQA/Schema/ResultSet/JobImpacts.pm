# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::ResultSet::JobImpacts;

use Mojo::Base 'DBIx::Class::ResultSet', -signatures;

use OpenQA::Jobs::Constants qw(RESTART_ORIGINS);

sub aggregate ($self, %cond) {
    my %job_cond;
    $job_cond{'job.group_id'} = $cond{group_id} if defined $cond{group_id};
    $job_cond{'job.BUILD'} = $cond{build} if defined $cond{build};
    $job_cond{'job.DISTRI'} = $cond{distri} if defined $cond{distri};
    $job_cond{'job.VERSION'} = $cond{version} if defined $cond{version};
    if ($cond{from} && $cond{to}) {
        $job_cond{'job.t_finished'} = {-between => [$cond{from}, $cond{to}]};
    }
    elsif ($cond{from}) {
        $job_cond{'job.t_finished'} = {'>=' => $cond{from}};
    }
    elsif ($cond{to}) {
        $job_cond{'job.t_finished'} = {'<=' => $cond{to}};
    }

    my $rs = $self->search(
        \%job_cond,
        {
            join => 'job',
            select => [
                'job.restart_origin',
                {count => 'me.job_id', -as => 'job_count'},
                {sum => 'me.seconds', -as => 'total_seconds'},
                {sum => 'me.energy_kwh', -as => 'total_energy_kwh'},
                {sum => 'me.carbon_g', -as => 'total_carbon_g'},
                {sum => 'me.cost_total', -as => 'total_cost'},
            ],
            as => [qw(restart_origin job_count total_seconds total_energy_kwh total_carbon_g total_cost)],
            group_by => ['job.restart_origin'],
        });

    my %by_origin = (first_run => {jobs => 0, seconds => 0, energy_kwh => 0, carbon_g => 0, cost_total => 0},);
    for my $orig (RESTART_ORIGINS) {
        $by_origin{$orig} = {jobs => 0, seconds => 0, energy_kwh => 0, carbon_g => 0, cost_total => 0};
    }

    my %total = (jobs => 0, seconds => 0, energy_kwh => 0, carbon_g => 0, cost_total => 0);

    while (my $row = $rs->next) {
        my $orig = $row->get_column('restart_origin');
        my $key = defined $orig ? $orig : 'first_run';
        my $count = int($row->get_column('job_count') // 0);
        my $sec = int($row->get_column('total_seconds') // 0);
        my $energy = ($row->get_column('total_energy_kwh') // 0) + 0;
        my $carbon = ($row->get_column('total_carbon_g') // 0) + 0;
        my $cost = ($row->get_column('total_cost') // 0) + 0;

        $by_origin{$key} = {
            jobs => $count,
            seconds => $sec,
            energy_kwh => $energy,
            carbon_g => $carbon,
            cost_total => $cost,
        };

        $total{jobs} += $count;
        $total{seconds} += $sec;
        $total{energy_kwh} += $energy;
        $total{carbon_g} += $carbon;
        $total{cost_total} += $cost;
    }

    return {
        total => \%total,
        by_origin => \%by_origin,
    };
}

sub added_latency ($self, %cond) {
    my $dbh = $self->result_source->schema->storage->dbh;
    my @where = ('parent.clone_id IS NOT NULL', 'clone.t_finished IS NOT NULL', 'parent.t_finished IS NOT NULL');
    my @bind;

    if (defined $cond{group_id}) {
        push @where, 'clone.group_id = ?';
        push @bind, $cond{group_id};
    }
    if (defined $cond{build}) {
        push @where, 'clone.build = ?';
        push @bind, $cond{build};
    }
    if (defined $cond{distri}) {
        push @where, 'clone.distri = ?';
        push @bind, $cond{distri};
    }
    if (defined $cond{version}) {
        push @where, 'clone.version = ?';
        push @bind, $cond{version};
    }
    if ($cond{from} && $cond{to}) {
        push @where, 'clone.t_finished BETWEEN ? AND ?';
        push @bind, $cond{from}, $cond{to};
    }

    my $where_sql = join ' AND ', @where;
    my $sql = "
        SELECT clone.restart_origin,
               SUM(EXTRACT(EPOCH FROM (clone.t_finished - parent.t_finished))) / 3600.0 AS latency_hours
        FROM jobs parent
        JOIN jobs clone ON parent.clone_id = clone.id
        WHERE $where_sql
        GROUP BY clone.restart_origin
    ";

    my $sth = $dbh->prepare($sql);
    $sth->execute(@bind);

    my %latency;
    for my $orig (RESTART_ORIGINS) {
        $latency{$orig} = 0;
    }

    while (my ($orig, $hours) = $sth->fetchrow_array) {
        $latency{$orig // 'unknown'} = ($hours // 0) + 0;
    }

    return \%latency;
}

1;
