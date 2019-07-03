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

package OpenQA::WebAPI::Plugin::ObsRsync::Plugin;
use Mojo::Base 'Mojolicious::Plugin';
use File::Basename;
use Mojo::Template;

use OpenQA::WebAPI::Plugin::ObsRsync::Controller;

sub register {
    my ($self, $app, $config) = @_;
    my $admin_r        = $config->{route} // $app->routes->find('admin_r') // $app->routes->any('/plugin');
    my $script_dirname = dirname(__FILE__);

    # Templates
    push @{$app->renderer->paths}, "$script_dirname/templates";

    $admin_r->get('/obs_rsync/#folder/logs/#subfolder/download/#filename')->name('plugin_obs_rsync_download_file')
      ->to('Plugin::ObsRsync::Controller#download_file');
    $admin_r->get('/obs_rsync/#folder/logs/#subfolder')->name('plugin_obs_rsync_logfiles')
      ->to('Plugin::ObsRsync::Controller#logfiles');
    $admin_r->get('/obs_rsync/#folder/logs')->name('plugin_obs_rsync_logs')->to('Plugin::ObsRsync::Controller#logs');
    $admin_r->get('/obs_rsync/#folder')->name('plugin_obs_rsync_folder')->to('Plugin::ObsRsync::Controller#folder');
    $admin_r->get('/obs_rsync/')->name('plugin_obs_rsync_index')->to('Plugin::ObsRsync::Controller#index');
    OpenQA::WebAPI::Plugin::ObsRsync::Controller::init_obs_rsync($app->{config}->{obs_rsync}->{home}, $app);
}

1;
