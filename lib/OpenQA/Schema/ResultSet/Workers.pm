# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::ResultSet::Workers;
use Mojo::Base 'DBIx::Class::ResultSet', -signatures;

use DateTime;
use Mojo::Date;
use OpenQA::App;
use OpenQA::Constants qw(WORKER_CLASS_LIMIT_REGEX DB_TIMESTAMP_ACCURACY);
use OpenQA::Jobs::Constants;
use OpenQA::WorkerReservation qw(RESERVATION_PROPERTIES reservation_active reservation_info reservation_error);

# maps the id of every worker holding a non-expired reservation to a hash with reservation properties,
# using a single query so that callers filtering many workers do not have to query the properties of each of them individually
sub active_reservations ($self) {
    my $properties = $self->result_source->schema->resultset('WorkerProperties')
      ->search({key => {-in => [RESERVATION_PROPERTIES]}}, {columns => [qw(worker_id key value)]});
    my %worker_props;
    while (my $property = $properties->next) {
        $worker_props{$property->worker_id}->{$property->key} = $property->value;
    }

    return {
        map { $_ => reservation_info($worker_props{$_}) }
        grep {
            my $p = $worker_props{$_};
            reservation_active($p->{RESERVED_BY_ID}, $p->{RESERVED_T_EXPIRES});
        } keys %worker_props
    };
}

sub stats ($self) {
    my $total = $self->count;
    my @online = grep { !$_->dead } $self->all;
    my $reserved = $self->active_reservations;

    return {
        total => $total,
        total_online => scalar @online,
        free_active_workers => scalar(grep { $_->is_free && !$reserved->{$_->id} } @online),
        free_broken_workers => scalar(grep { !$_->job_id && defined $_->error } @online),
        busy_workers => scalar(grep { $_->job_id } @online),
        reserved_workers => scalar(grep { $_->is_free && $reserved->{$_->id} } @online),
    };
}

sub reserve_host ($self, $host, $user, %args) {
    my $is_admin = $user->is_admin;
    die reservation_error(forbidden => 'Insufficient permissions to reserve a worker')
      unless $is_admin || $user->is_operator;

    my @workers = $self->search({host => $host})->all;
    die reservation_error(not_found => "Worker host '$host' not found") unless @workers;

    $self->result_source->schema->txn_do(
        sub {
            my @conflicts;
            for my $worker (@workers) {
                if ($worker->is_reserved) {
                    my $owner_id = $worker->_reservation_properties->{RESERVED_BY_ID};
                    push @conflicts, $worker->name if $owner_id != $user->id && !($args{force} && $is_admin);
                }
            }
            if (@conflicts) {
                die reservation_error(
                    conflict => 'Worker host matches instances already reserved by: ' . join ', ',
                    @conflicts
                );
            }

            $_->reserve($user, $args{comment}, $args{duration}, $args{force}, $args{worker_class}, 'host') for @workers;
        });

    return \@workers;
}

sub release_host ($self, $host, $user, %args) {
    my $is_admin = $user->is_admin;
    die reservation_error(forbidden => 'Insufficient permissions to release a worker')
      unless $is_admin || $user->is_operator;

    my @workers = $self->search({host => $host})->all;
    die reservation_error(not_found => "Worker host '$host' not found") unless @workers;

    $self->result_source->schema->txn_do(
        sub {
            my (@foreign_owned, @reserved);
            for my $worker (@workers) {
                if ($worker->is_reserved) {
                    push @reserved, $worker;
                    my $owner_id = $worker->_reservation_properties->{RESERVED_BY_ID};
                    push @foreign_owned, $worker->name if $owner_id != $user->id && !$is_admin;
                }
            }

            if (@foreign_owned) {
                die reservation_error(
                    forbidden => 'Insufficient permissions to release reservation owned by other users on: '
                      . join ', ',
                    @foreign_owned
                );
            }

            $_->release($user) for @reserved;
        });

    return \@workers;
}

sub _iso_timestamp ($t) { Mojo::Date->new(int Mojo::Date->new($t)->epoch)->to_datetime }

sub _db_timestamp ($self, $dt) { $self->result_source->schema->storage->datetime_parser->format_datetime($dt) }

sub last_jobs_finished_per_worker ($self, $worker_ids) {
    return {} unless @$worker_ids;
    my $rs = $self->result_source->schema->resultset('Jobs')->search(
        {assigned_worker_id => {-in => $worker_ids}, state => DONE, t_finished => {'!=' => undef}},
        {
            select => ['assigned_worker_id', {max => 't_finished'}],
            as => [qw(worker_id last_finished)],
            group_by => ['assigned_worker_id']});
    return {map { $_->get_column('worker_id') => _iso_timestamp($_->get_column('last_finished')) } $rs->all};
}

sub host_activity_summary ($self, $days = 30) {
    my @all_workers = $self->all;
    return {} unless @all_workers;
    my @worker_ids = map { $_->id } @all_workers;
    my $last_finished_map = $self->last_jobs_finished_per_worker(\@worker_ids);

    my $now = DateTime->now(time_zone => 'UTC');
    my $dt_recent = $now->clone->subtract(days => $days);
    my $dt_7 = $now->clone->subtract(days => 7);
    my $dt_30 = $now->clone->subtract(days => 30);
    my $cutoff_str = $self->_db_timestamp($days > 30 ? $dt_recent : $dt_30);
    my $dt_recent_str = $self->_db_timestamp($dt_recent);
    my $dt_7_str = $self->_db_timestamp($dt_7);
    my $dt_30_str = $self->_db_timestamp($dt_30);

    my $jobs_rs = $self->result_source->schema->resultset('Jobs')->search(
        {assigned_worker_id => {-in => \@worker_ids}, state => DONE, t_finished => {'>=' => $cutoff_str}},
        {
            select => [
                'assigned_worker_id',
                \['COUNT(CASE WHEN t_finished >= ? THEN 1 END)', $dt_recent_str],
                \['COUNT(CASE WHEN t_finished >= ? THEN 1 END)', $dt_7_str],
                \['COUNT(CASE WHEN t_finished >= ? THEN 1 END)', $dt_30_str],
            ],
            as => [qw(worker_id count_in_window count_7d count_30d)],
            group_by => ['assigned_worker_id']});

    my (%in_window, %last7, %last30);
    for my $row ($jobs_rs->all) {
        my $wid = $row->get_column('worker_id');
        $in_window{$wid} = $row->get_column('count_in_window');
        $last7{$wid} = $row->get_column('count_7d');
        $last30{$wid} = $row->get_column('count_30d');
    }

    my %hosts;
    for my $w (@all_workers) {
        my $entry = (
            $hosts{$w->host} //= {
                total_instances => 0,
                online_instances => 0,
                last_job_finished => undef,
                idle_seconds => undef,
                jobs_in_window => 0,
                jobs_last_7d => 0,
                jobs_last_30d => 0,
                worker_classes => {},
                busy => 0,
            });
        $entry->{total_instances}++;
        $entry->{online_instances}++ unless $w->dead;
        my $wid = $w->id;
        $entry->{jobs_in_window} += $in_window{$wid} || 0;
        $entry->{jobs_last_7d} += $last7{$wid} || 0;
        $entry->{jobs_last_30d} += $last30{$wid} || 0;
        $entry->{busy} = 1 if $w->job_id;
        if (my $lf = $last_finished_map->{$wid}) {
            $entry->{last_job_finished} = $lf
              if !$entry->{last_job_finished} || $lf gt $entry->{last_job_finished};
        }
        if (my $class_prop = $w->get_property('WORKER_CLASS')) {
            for my $c (split /,/, $class_prop) {
                $c =~ s/${\WORKER_CLASS_LIMIT_REGEX}/$1/;
                $entry->{worker_classes}{$c} = 1;
            }
        }
    }

    for my $h (values %hosts) {
        $h->{worker_classes} = [sort keys %{$h->{worker_classes}}];
        $h->{idle_seconds} = time - Mojo::Date->new($h->{last_job_finished})->epoch if $h->{last_job_finished};
        $h->{is_idle} = ($h->{jobs_in_window} == 0 && !$h->{busy}) ? 1 : 0;
        delete $h->{busy};
    }
    return \%hosts;
}

# Returns a resultset (or list of rows in list context). Both filters run in SQL so
# callers can page without loading all workers.
sub find_unused_workers ($self, %args) {
    my $days = $args{threshold_days} // 14;
    my $online_only = $args{online_only} // 1;
    my $me = $self->current_source_alias;
    my $now = DateTime->now(time_zone => 'UTC');
    my $recent_threshold = $self->_db_timestamp($now->clone->subtract(days => $days));
    my @conditions = (
        {"$me.job_id" => undef},
        \[
"NOT EXISTS (SELECT 1 FROM jobs j WHERE j.assigned_worker_id = $me.id AND j.state = ? AND j.t_finished >= ?)",
            DONE,
            $recent_threshold
        ]);
    if ($online_only) {
        my $timeout = OpenQA::App->singleton->config->{global}->{worker_timeout} - DB_TIMESTAMP_ACCURACY;
        push @conditions, {"$me.t_seen" => {'>=' => $self->_db_timestamp($now->clone->subtract(seconds => $timeout))}};
    }
    return $self->search({-and => \@conditions});
}

sub find_unused_hosts ($self, %args) {
    my $days = $args{threshold_days} // 14;
    my $online_only = $args{online_only} // 1;
    my $summary = $self->host_activity_summary($days);
    my @hosts;
    for my $host (sort keys %$summary) {
        my $s = $summary->{$host};
        next if $online_only && $s->{online_instances} == 0;
        next unless $s->{is_idle};
        push @hosts, {host => $host, %{$s}};
    }
    return @hosts;
}

1;
