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
use Mojolicious::Static;
use Mojo::File;

sub index {
    my ($self) = @_;

    $self->render('admin/asset/index');
}

sub _serve_status_json_from_cache {
    my ($self) = @_;

    my $cache_file = OpenQA::Schema::ResultSet::Assets::status_cache_file();
    return unless (-f $cache_file);

    OpenQA::Utils::log_debug('Serving static asset status: ' . $cache_file);
    $self->{static} = Mojolicious::Static->new;
    $self->{static}->extra({'cache.json' => $cache_file});
    $self->{static}->serve($self, 'cache.json');
    return 1;
}

sub status_json {
    my ($self) = @_;

    # fail if cleanup is currently ongoing (the static JSON file might be written right now)
    if ($self->gru->is_task_active('limit_assets')) {
        return $self->render(json => {error => 'Asset cleanup is currently ongoing.'}, status => 400);
    }

    # allow to force scan for untracked assets and refresh
    my $force_refresh = $self->param('force_refresh');
    my $assets        = $self->app->schema->resultset('Assets');
    if ($force_refresh) {
        $assets->scan_for_untracked_assets();
        $assets->refresh_assets();
    }

    # serve previously cached, static JSON file unless $force_refresh has been specified
    if (!$force_refresh) {
        return !!$self->rendered if $self->_serve_status_json_from_cache;
    }

    # generate new static JSON file
    $assets->status(
        compute_pending_state_and_max_job => $force_refresh,
        compute_max_job_by_group          => 0,
    );

    return !!$self->rendered if $self->_serve_status_json_from_cache;
    return $self->render(json => {error => 'cache file for asset status not found'}, status => 500);
}

1;
