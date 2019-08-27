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
use Mojo::UserAgent;

sub register {
    my ($self, $app, $config) = @_;
    my $plugin_r     = $app->routes->find('ensure_operator');
    my $plugin_api_r = $app->routes->find('api_ensure_operator');

    if (!$plugin_r) {
        $app->log->error('Routes not configured, plugin ObsRsync will be disabled') unless $plugin_r;
    }
    else {
        $app->helper('obs_rsync.home'               => sub { shift->app->config->{obs_rsync}->{home} });
        $app->helper('obs_rsync.concurrency'        => sub { shift->app->config->{obs_rsync}->{concurrency} });
        $app->helper('obs_rsync.retry_interval'     => sub { shift->app->config->{obs_rsync}->{retry_interval} });
        $app->helper('obs_rsync.queue_limit'        => sub { shift->app->config->{obs_rsync}->{queue_limit} });
        $app->helper('obs_rsync.project_status_url' => sub { shift->app->config->{obs_rsync}->{project_status_url} });
        $app->helper(
            'obs_rsync.is_status_dirty' => sub {
                my ($c, $project) = @_;
                my $url = $c->obs_rsync->project_status_url;
                return undef unless $url;
                return _is_obs_project_status_dirty($url, $project);
            });
        $app->helper('obs_rsync.check_and_render_error' => \&_check_and_render_error);

        # Templates
        push @{$app->renderer->paths},
          Mojo::File->new(__FILE__)->dirname->child('ObsRsync')->child('templates')->to_string;

        $plugin_r->get('/obs_rsync/queue')->name('plugin_obs_rsync_queue')
          ->to('Plugin::ObsRsync::Controller::Gru#index');
        $plugin_r->post('/obs_rsync/#folder/runs')->name('plugin_obs_rsync_run')
          ->to('Plugin::ObsRsync::Controller::Gru#run');

        $plugin_r->get('/obs_rsync/#folder/runs/#subfolder/download/#filename')->name('plugin_obs_rsync_download_file')
          ->to('Plugin::ObsRsync::Controller::Folders#download_file');
        $plugin_r->get('/obs_rsync/#folder/runs/#subfolder')->name('plugin_obs_rsync_run')
          ->to('Plugin::ObsRsync::Controller::Folders#run');
        $plugin_r->get('/obs_rsync/#folder/runs')->name('plugin_obs_rsync_runs')
          ->to('Plugin::ObsRsync::Controller::Folders#runs');
        $plugin_r->get('/obs_rsync/#folder')->name('plugin_obs_rsync_folder')
          ->to('Plugin::ObsRsync::Controller::Folders#folder');
        $plugin_r->get('/obs_rsync/')->name('plugin_obs_rsync_index')
          ->to('Plugin::ObsRsync::Controller::Folders#index');
        $app->config->{plugin_links}{operator}{'OBS Sync'} = 'plugin_obs_rsync_index';
    }

    if (!$plugin_api_r) {
        $app->log->error('API routes not configured, plugin ObsRsync will not have API configured') unless $plugin_r;
    }
    else {
        $plugin_api_r->put('/obs_rsync/#folder/runs')->name('plugin_obs_rsync_api_run')
          ->to('Plugin::ObsRsync::Controller::Gru#run');
    }

    $app->plugin('OpenQA::WebAPI::Plugin::ObsRsync::Task');
}

# try to determine whether project is dirty
# undef means status is unknown
sub _is_obs_project_status_dirty {
    my ($url, $project) = @_;
    return undef unless $url;

    $url =~ s/%%PROJECT/$project/g;
    my $ua = Mojo::UserAgent->new;

    my $res = $ua->get($url)->result;
    return undef unless $res->is_success;

    return _parse_obs_response_dirty($res->body);
}

sub _parse_obs_response_dirty {
    my ($body) = @_;

    my $dirty;
    return 1 if $body =~ /dirty/g;
    while ($body =~ /^(.*repository="images".*)/gm) {
        my $line = $1;
        if ($line =~ /state="([a-z]+)"/) {
            return 1 if $1 ne 'published';
            $dirty //= 0;
        }
    }
    return $dirty;
}

sub _check_and_render_error {
    my ($c, @args) = @_;
    my ($code, $message) = _check_error($c->obs_rsync->home, @args);
    $c->render(json => {error => $message}, status => $code) if $code;
    return $code;
}

sub _check_error {
    my ($home, $project, $subfolder, $filename) = @_;
    return (405, 'Home directory is not set') unless $home;
    return (405, 'Home directory not found')  unless -d $home;
    return (400, 'Project has invalid characters')   if $project   && $project =~ m!/!;
    return (400, 'Subfolder has invalid characters') if $subfolder && $subfolder =~ m!/!;
    return (400, 'Filename has invalid characters')  if $filename  && $filename =~ m!/!;

    return (404, 'Invalid Project {' . $project . '}') if $project && !-d Mojo::File->new($home, $project);
    return 0;
}

1;
