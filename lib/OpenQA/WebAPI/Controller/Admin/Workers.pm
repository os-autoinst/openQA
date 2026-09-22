# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::Admin::Workers;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use OpenQA::Utils;
use OpenQA::WebAPI::ServerSideDataTable;
use Scalar::Util 'looks_like_number';

sub _extend_info ($w) {
    my $info = $w->info;
    $info->{name} = $w->name;
    my $error = $info->{error};
    if ($error && ($error =~ qr/(graceful disconnect|limited) at (.*)/)) {
        $info->{offline_note} = $1;
        $info->{t_seen} = $2 . 'Z';
        $info->{alive} = undef;
        $info->{status} = 'dead';
    }
    elsif (my $last_seen = $w->t_seen) {
        $info->{t_seen} = $last_seen->datetime . 'Z';
    }
    else {
        $info->{t_seen} = 'never';
    }
    return $info;
}

sub _reservation_default_duration ($self) {
    change_sec_to_word($self->app->config->{worker_reservation}->{default_duration});
}

sub index ($self) {
    my $workers_db = $self->schema->resultset('Workers');
    my $worker_stats = $workers_db->stats;

    my %workers;
    while (my $w = $workers_db->next) {
        next unless $w->id;
        $workers{$w->name} = _extend_info($w);
    }
    $self->stash(
        reservation_default_duration => $self->_reservation_default_duration,
        workers_online => $worker_stats->{total_online},
        total => $worker_stats->{total},
        workers_active_free => $worker_stats->{free_active_workers},
        workers_broken_free => $worker_stats->{free_broken_workers},
        workers_busy => $worker_stats->{busy_workers},
        workers_reserved => $worker_stats->{reserved_workers},
        is_admin => !!$self->is_admin,
        workers => \%workers
    );

    $self->respond_to(
        json => {json => {workers => \%workers}},
        html => {template => 'admin/workers/index'});
}

sub show ($self) {
    my $w = $self->schema->resultset('Workers')->find($self->param('worker_id'))
      or return $self->reply->not_found;
    $self->stash(worker => _extend_info($w), reservation_default_duration => $self->_reservation_default_duration);

    $self->render('admin/workers/show');
}

sub show_host ($self) {
    my $worker_host = $self->param('worker_host');
    my @workers = $self->schema->resultset('Workers')->search({host => $worker_host})->all;
    return $self->reply->not_found unless @workers;

    my $dead = grep { $_->dead } @workers;
    my $stats = {
        dead => $dead,
        online => @workers - $dead,
        busy => scalar(grep { !$_->dead && $_->status eq 'running' } @workers),
        reserved => scalar(grep { !$_->dead && $_->status eq 'reserved' } @workers),
        idle => scalar(grep { !$_->dead && $_->status eq 'idle' } @workers),
    };

    my $reserved_count = grep { $_->is_reserved } @workers;
    my $reservation_status
      = $reserved_count == @workers ? 'fully reserved' : $reserved_count ? 'partially reserved' : 'unreserved';
    my ($first_reserved) = grep { $_->is_reserved } @workers;

    my (%prop_values, %distinct_classes);
    for my $w (@workers) {
        for my $p ($w->properties->all) {
            $prop_values{$p->key}->{$p->value}++;
            if ($p->key eq 'WORKER_CLASS') {
                $distinct_classes{$_} = 1 for split /,/, $p->value;
            }
        }
    }

    my (%shared_props, %different_props);
    for my $k (keys %prop_values) {
        my @vals = keys %{$prop_values{$k}};
        if (@vals == 1 && $prop_values{$k}->{$vals[0]} == @workers) {
            $shared_props{$k} = $vals[0];
        }
        else {
            $different_props{$k} = $prop_values{$k};
        }
    }

    my $shared_data = {
        worker_host => $worker_host,
        workers => [map { _extend_info($_) } @workers],
        stats => $stats,
        shared_properties => \%shared_props,
        different_properties => \%different_props,
        worker_classes => [sort keys %distinct_classes],
    };

    $self->stash(
        %$shared_data,
        reservation_status => $reservation_status,
        host_reservation => $first_reserved ? $first_reserved->reservation : undef,
        reservation_default_duration => $self->_reservation_default_duration,
        is_admin => !!$self->is_admin,
    );

    $self->respond_to(
        json => {json => $shared_data},
        html => {template => 'admin/workers/show_host'});
}

sub host_previous_jobs_ajax ($self) {
    my $worker_host = $self->param('worker_host');
    my @worker_ids = map { $_->id } $self->schema->resultset('Workers')->search({host => $worker_host})->all;

    OpenQA::WebAPI::ServerSideDataTable::render_response(
        controller => $self,
        resultset => 'Jobs',
        columns => [
            [qw(BUILD DISTRI VERSION FLAVOR ARCH)],
            [qw(passed_module_count softfailed_module_count failed_module_count)],
            qw(t_finished),
        ],
        initial_conds => [{assigned_worker_id => {-in => \@worker_ids}}],
        additional_params => {prefetch => [qw(children parents assigned_worker)]},
        prepare_data_function => sub ($results) {
            return [
                map {
                    {
                        DT_RowId => 'job_' . $_->id,
                        id => $_->id,
                        name => $_->name,
                        worker => $_->assigned_worker ? $_->assigned_worker->instance : undef,
                        deps => $_->dependencies,
                        result => $_->result,
                        result_stats => $_->result_stats,
                        state => $_->state,
                        clone => $_->clone_id,
                        finished => $_->t_finished ? $_->t_finished->datetime() . 'Z' : undef,
                    }
                } $results->all
            ];
        },
    );
}

sub previous_jobs_ajax ($self) {
    OpenQA::WebAPI::ServerSideDataTable::render_response(
        controller => $self,
        resultset => 'Jobs',
        columns => [
            [qw(BUILD DISTRI VERSION FLAVOR ARCH)],
            [qw(passed_module_count softfailed_module_count failed_module_count)],
            qw(t_finished),
        ],
        initial_conds => [{assigned_worker_id => $self->param('worker_id')}],
        additional_params => {prefetch => [qw(children parents)]},
        prepare_data_function => sub ($results) {
            return [
                map {
                    {
                        DT_RowId => 'job_' . $_->id,
                        id => $_->id,
                        name => $_->name,
                        deps => $_->dependencies,
                        result => $_->result,
                        result_stats => $_->result_stats,
                        state => $_->state,
                        clone => $_->clone_id,
                        finished => $_->t_finished ? $_->t_finished->datetime() . 'Z' : undef,
                    }
                } $results->all
            ];
        },
    );
}

1;
