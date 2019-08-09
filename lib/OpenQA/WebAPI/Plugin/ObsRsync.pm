# Copyright (C) 2019 SUSE Linux GmbH
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

package OpenQA::WebAPI::Plugin::ObsRsync;
use Mojo::Base 'Mojolicious::Plugin';
use Mojo::File;
use OpenQA::WebAPI::Plugin::ObsRsync::Controller;

sub register {
    my ($self, $app, $config) = @_;
    my $plugin_r     = $app->routes->find('ensure_operator');
    my $plugin_api_r = $app->routes->find('api_ensure_operator');

    if (!$plugin_r) {
        $app->log->error('Routes not configured, plugin ObsRsync will be disabled') unless $plugin_r;
    }
    else {
        # Templates
        push @{$app->renderer->paths},
          Mojo::File->new(__FILE__)->dirname->child('ObsRsync')->child('templates')->to_string;

        $plugin_r->get('/obs_rsync/#folder/runs/#subfolder/download/#filename')->name('plugin_obs_rsync_download_file')
          ->to('Plugin::ObsRsync::Controller#download_file');
        $plugin_r->get('/obs_rsync/#folder/runs/#subfolder')->name('plugin_obs_rsync_logfiles')
          ->to('Plugin::ObsRsync::Controller#logfiles');
        $plugin_r->get('/obs_rsync/#folder/runs')->name('plugin_obs_rsync_logs')
          ->to('Plugin::ObsRsync::Controller#logs');
        $plugin_r->get('/obs_rsync/#folder')->name('plugin_obs_rsync_folder')
          ->to('Plugin::ObsRsync::Controller#folder');
        $plugin_r->get('/obs_rsync/')->name('plugin_obs_rsync_index')->to('Plugin::ObsRsync::Controller#index');
        $app->config->{plugin_links}{operator}{'OBS Sync'} = 'plugin_obs_rsync_index';
    }

    if (!$plugin_api_r) {
        $app->log->error('API routes not configured, plugin ObsRsync will not have API configured') unless $plugin_r;
    }
    else {
        $plugin_api_r->put('/obs_rsync/#folder/runs')->name('plugin_obs_rsync_run')
          ->to('Plugin::ObsRsync::Controller#run');
    }

    OpenQA::WebAPI::Plugin::ObsRsync::Controller::register($app);
}

1;
