# Copyright (C) 2014-2018 SUSE Linux Products GmbH
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

package OpenQA::WebAPI::Controller::Admin::Asset;
use Mojo::Base 'Mojolicious::Controller';
use List::Util 'sum';

sub index {
    my ($self) = @_;

    # allow to force scan for untracked assets and refresh
    my $force_refresh = $self->param('force_refresh');
    if ($force_refresh) {
        my $assets = $self->app->schema->resultset('Assets');
        $assets->scan_for_untracked_assets();
        $assets->refresh_assets();
    }

    my $status = $self->db->resultset('Assets')->status(
        compute_pending_state_and_max_job => $force_refresh,
        compute_max_job_by_group          => 0,
    );
    my $total_size = sum(map { $_->{picked} } values(%{$status->{groups}}));

    $self->stash('assets',     $status->{assets});
    $self->stash('groups',     $status->{groups});
    $self->stash('total_size', $total_size);

    $self->respond_to(
        json => {json     => $status},
        html => {template => 'admin/asset/index'},
    );
}

1;
