# Copyright (C) 2015-2020 SUSE LLC
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

package OpenQA::WebAPI::Controller::Admin::Workers;
use Mojo::Base 'Mojolicious::Controller';

use OpenQA::Utils;
use OpenQA::WebAPI::ServerSideDataTable;
use Scalar::Util 'looks_like_number';

sub _extend_info {
    my ($w, $live) = @_;
    $live //= 0;
    my $info = $w->info($live);
    $info->{name} = $w->name;
    if ($live && ($info->{error} =~ qr/(graceful disconnect) at (.*)/)) {
        $info->{offline_note} = $1;
        $info->{t_seen}       = $2 . 'Z';
    }
    elsif (my $last_seen = $w->t_seen) {
        $info->{t_seen} = $last_seen->datetime . 'Z';
    }
    else {
        $info->{t_seen} = 'never';
    }
    return $info;
}

sub index {
    my ($self) = @_;

    my $workers_db          = $self->schema->resultset('Workers');
    my $total_online        = grep { !$_->dead } $workers_db->all();
    my $total               = $workers_db->count;
    my $free_active_workers = grep { !$_->dead } $workers_db->search({job_id => undef, error => undef})->all();
    my $free_broken_workers
      = grep { !$_->dead } $workers_db->search({job_id => undef, error => {'!=' => undef}})->all();
    my $busy_workers = grep { !$_->dead } $workers_db->search({job_id => {'!=' => undef}})->all();
    # possible performance improvement: do check for dead via database

    my %workers;
    while (my $w = $workers_db->next) {
        next unless $w->id;
        $workers{$w->name} = _extend_info($w);
    }

    my $is_admin = 0;
    $is_admin = 1 if ($self->is_admin);

    $self->stash(
        workers_online      => $total_online,
        total               => $total,
        workers_active_free => $free_active_workers,
        workers_broken_free => $free_broken_workers,
        workers_busy        => $busy_workers,
        is_admin            => $is_admin,
        workers             => \%workers
    );

    $self->respond_to(
        json => {json     => {workers => \%workers}},
        html => {template => 'admin/workers/index'});
}

sub show {
    my ($self) = @_;

    my $w = $self->schema->resultset('Workers')->find($self->param('worker_id'))
      or return $self->reply->not_found;
    $self->stash(worker => _extend_info($w, 1));

    $self->render('admin/workers/show');
}

sub previous_jobs_ajax {
    my ($self) = @_;

    OpenQA::WebAPI::ServerSideDataTable::render_response(
        controller => $self,
        resultset  => 'Jobs',
        columns    => [
            [qw(BUILD DISTRI VERSION FLAVOR ARCH)],
            [qw(passed_module_count softfailed_module_count failed_module_count)],
            qw(t_finished),
        ],
        initial_conds         => [{assigned_worker_id => $self->param('worker_id')}],
        additional_params     => {prefetch => [qw(children parents)]},
        prepare_data_function => sub {
            my ($results) = @_;
            my @jobs = $results->all;
            my @data;
            for my $job (@jobs) {
                my $job_id = $job->id;
                push(
                    @data,
                    {
                        DT_RowId     => 'job_' . $job_id,
                        id           => $job_id,
                        name         => $job->name,
                        deps         => $job->dependencies,
                        result       => $job->result,
                        result_stats => $job->result_stats,
                        state        => $job->state,
                        clone        => $job->clone_id,
                        finished     => ($job->t_finished ? ($job->t_finished->datetime() . 'Z') : undef),
                    });
            }
            return \@data;
        },
    );
}

1;
