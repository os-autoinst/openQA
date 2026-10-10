# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::ResultSet::Workers;
use Mojo::Base 'DBIx::Class::ResultSet', -signatures;

use DateTime;
use Mojo::Date;
use OpenQA::Constants qw(WORKER_CLASS_LIMIT_REGEX);
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

sub _iso_timestamp ($t) {
    return undef unless defined $t;
    return $t if $t =~ /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
    my $epoch = Mojo::Date->new($t)->epoch;
    return defined $epoch ? Mojo::Date->new($epoch)->to_datetime : undef;
}

sub last_jobs_finished_per_worker ($self, $worker_ids) {
    return {} unless @$worker_ids;
    my $rs = $self->result_source->schema->resultset('Jobs')->search(
        {assigned_worker_id => {-in => $worker_ids}, state => 'done', t_finished => {'!=' => undef}},
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
    my $dt_cutoff = $now->clone->subtract(days => ($days > 30 ? $days : 30));
    my $cutoff_str = $self->result_source->schema->storage->datetime_parser->format_datetime($dt_cutoff);

    my (%recent, %last7, %last30);
    my $rs
      = $self->result_source->schema->resultset('Jobs')
      ->search({assigned_worker_id => {-in => \@worker_ids}, state => 'done', t_finished => {'>=' => $cutoff_str}},
        {select => ['assigned_worker_id', 't_finished']});
    while (my $job = $rs->next) {
        my $wid = $job->assigned_worker_id;
        my $tf = $job->t_finished;
        $recent{$wid}++ if $tf >= $dt_recent;
        $last7{$wid}++ if $tf >= $dt_7;
        $last30{$wid}++ if $tf >= $dt_30;
    }

    my %hosts;
    for my $w (@all_workers) {
        my $host = $w->host;
        $hosts{$host} //= {
            total_instances => 0,
            online_instances => 0,
            last_job_finished => undef,
            idle_seconds => undef,
            jobs_count_recent => 0,
            jobs_last_7d => 0,
            jobs_last_30d => 0,
            worker_classes => {},
            busy => 0
        };
        $hosts{$host}{total_instances}++;
        $hosts{$host}{online_instances}++ unless $w->dead;
        my $wid = $w->id;
        $hosts{$host}{jobs_count_recent} += $recent{$wid} || 0;
        $hosts{$host}{jobs_last_7d} += $last7{$wid} || 0;
        $hosts{$host}{jobs_last_30d} += $last30{$wid} || 0;
        $hosts{$host}{busy} = 1 if $w->job_id;
        if (my $lf = $last_finished_map->{$wid}) {
            $hosts{$host}{last_job_finished} = $lf
              if !$hosts{$host}{last_job_finished} || $lf gt $hosts{$host}{last_job_finished};
        }
        if (my $class_prop = $w->get_property('WORKER_CLASS')) {
            for my $c (split /,/, $class_prop) {
                $c =~ s/${\WORKER_CLASS_LIMIT_REGEX}/$1/;
                $hosts{$host}{worker_classes}{$c} = 1;
            }
        }
    }

    for my $h (values %hosts) {
        $h->{worker_classes} = [sort keys %{$h->{worker_classes}}];
        $h->{idle_seconds} = time - Mojo::Date->new($h->{last_job_finished})->epoch if $h->{last_job_finished};
        $h->{is_idle} = ($h->{jobs_count_recent} == 0 && !$h->{busy}) ? 1 : 0;
        delete $h->{busy};
    }
    return \%hosts;
}

sub find_unused_workers ($self, %args) {
    my $days = $args{threshold_days} // 14;
    my $online_only = $args{online_only} // 1;
    my $threshold = Mojo::Date->new(DateTime->now(time_zone => 'UTC')->subtract(days => $days)->epoch)->to_datetime;

    my @workers = $self->all;
    my $last_finished_map = $self->last_jobs_finished_per_worker([map { $_->id } @workers]);
    return grep {
           !($online_only && $_->dead)
        && !$_->job_id
          && (!defined $last_finished_map->{$_->id} || $last_finished_map->{$_->id} lt $threshold)
    } @workers;
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
