# Copyright (C) 2015 SUSE Linux GmbH
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package OpenQA::WebAPI::Controller::Admin::Workers;
use Mojo::Base 'Mojolicious::Controller';
use OpenQA::Utils;
use Scalar::Util 'looks_like_number';

sub _extend_info {
    my ($w) = @_;
    my $info = $w->info;
    $info->{name}      = $w->name;
    $info->{t_updated} = $w->t_updated;
    return $info;
}

sub index {
    my ($self) = @_;

    my $workers = $self->db->resultset('Workers');
    my %workers;
    while (my $w = $workers->next) {
        next unless $w->id;
        $workers{$w->name} = _extend_info($w);
    }
    $self->stash(workers => \%workers);

    $self->render('admin/workers/index');
}

sub show {
    my ($self) = @_;

    my $w = $self->db->resultset('Workers')->find($self->param('worker_id'))
      or return $self->reply->not_found;
    $self->stash(worker => _extend_info($w));

    $self->render('admin/workers/show');
}

sub previous_jobs_ajax {
    my ($self) = @_;

    my $worker = $self->db->resultset('Workers')->find($self->param('worker_id'))
      or return $self->render(
        json   => {error => 'Specified worker does not exist'},
        status => 404
      );

    my $total_count = $worker->previous_jobs->count;

    # Parameter for order
    my @columns = qw(id result t_finished);
    my @order_by_params;
    my $index = 0;
    while (1) {
        my $column_index = $self->param("order[$index][column]") // @columns;
        my $column_order = $self->param("order[$index][dir]");
        last unless $column_index < @columns && grep { $column_order eq $_ } qw(asc desc);
        push(@order_by_params, {'-' . $column_order => $columns[$column_index]});
        ++$index;
    }
    my %params = (order_by => \@order_by_params);

    # Determine number of needles with all filters applied except paging
    my $filtered_count = $worker->previous_jobs({}, \%params)->count;

    # Parameter for paging
    my $first_row = $self->param('start');
    $params{offset} = $first_row if $first_row;
    my $row_limit = $self->param('length');
    $params{rows} = $row_limit if $row_limit;
    $params{prefetch} = [qw(children parents)];

    my @jobs = $worker->previous_jobs({}, \%params)->all;
    my @ids = map { $_->id } @jobs;
    my $stats = OpenQA::Schema::Result::JobModules::job_module_stats(\@ids);

    my @data;
    my %modules;
    for my $job (@jobs) {
        push(
            @data,
            {
                id           => $job->id,
                name         => $job->name,
                deps         => $job->dependencies,
                result       => $job->result,
                result_stats => $stats->{$job->id},
                state        => $job->state,
                clone        => $job->clone_id,
                finished     => $job->t_finished ? $job->t_finished->datetime() . 'Z' : undef,
            });
    }
    $self->render(
        json => {
            recordsTotal    => $total_count,
            recordsFiltered => $filtered_count,
            data            => \@data
        });
}

1;
# vim: set sw=4 et:
