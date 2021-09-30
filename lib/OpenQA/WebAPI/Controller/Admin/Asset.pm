# Copyright 2014-2018 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::Admin::Asset;
use Mojo::Base 'Mojolicious::Controller';

use Mojolicious::Static;
use Mojo::File;
use OpenQA::Log 'log_debug';

sub index {
    my ($self) = @_;

    $self->render('admin/asset/index');
}

sub _serve_status_json_from_cache {
    my ($self) = @_;

    my $cache_file = OpenQA::Schema::ResultSet::Assets::status_cache_file();
    return unless (-f $cache_file);

    log_debug('Serving static asset status: ' . $cache_file);
    $self->{static} = Mojolicious::Static->new;
    $self->{static}->extra({'cache.json' => $cache_file});
    $self->{static}->serve($self, 'cache.json');
    return 1;
}

sub status_json {
    my ($self) = @_;

    # serve previously cached, static JSON file unless $force_refresh has been specified
    my $force_refresh = $self->param('force_refresh');
    return !!$self->rendered if !$force_refresh && $self->_serve_status_json_from_cache;

    # fail if cleanup is currently ongoing and there is no cache file yet
    if ($self->gru->is_task_active('limit_assets')) {
        return $self->render(json => {error => 'Asset cleanup is currently ongoing.'}, status => 400);
    }

    # allow to force scan for untracked assets and refresh
    my $assets = $self->app->schema->resultset('Assets');
    if ($force_refresh) {
        $assets->scan_for_untracked_assets();
        $assets->refresh_assets();
    }

    # generate new static JSON file
    $assets->status(
        compute_pending_state_and_max_job => $force_refresh,
        compute_max_job_by_group => 0,
    );

    return !!$self->rendered if $self->_serve_status_json_from_cache;
    $self->render(json => {error => 'Cache file for asset status could not be generated.'}, status => 500);
}

1;
