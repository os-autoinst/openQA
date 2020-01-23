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
use POSIX 'strftime';

my $dirty_status_filename = '.dirty_status';
my $files_iso_filename    = 'files_iso.lst';

my $lock_timeout = 360000;

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
                my ($c, $project, $trace) = @_;
                my $helper = $c->obs_rsync;
                my $url    = $helper->project_status_url;
                return undef unless $url;
                ($project, undef) = $helper->split_project_batch($project);
                my @res = $self->_is_obs_project_status_dirty($url, $project);
                if ($trace && scalar @res > 1 && $res[1]) {
                    # ignore potential errors because we use this only for cosmetic rendering
                    open(my $fh, '>', Mojo::File->new($c->obs_rsync->home, $project, $dirty_status_filename))
                      or return $res[0];
                    print $fh $res[1];
                    close $fh;
                }
                return $res[0];
            });
        $app->helper('obs_rsync.split_project_batch' => \&_split_project_batch);
        $app->helper('obs_rsync.get_batches'         => \&_get_batches);
        $app->helper('obs_rsync.get_first_batch'     => \&_get_first_batch);
        $app->helper('obs_rsync.get_run_last_info'   => \&_get_run_last_info);
        $app->helper(
            'obs_rsync.get_fail_last_info' => sub {
                my ($c, $project) = @_;
                return _get_last_failed_job($c, $project, 1);
            });
        $app->helper('obs_rsync.get_dirty_status'       => \&_get_dirty_status);
        $app->helper('obs_rsync.get_obs_version'        => \&_get_obs_version);
        $app->helper('obs_rsync.check_and_render_error' => \&_check_and_render_error);

        $app->helper('obs_rsync.log_job_id'        => \&_log_job_id);
        $app->helper('obs_rsync.log_failure'       => \&_log_failure);
        $app->helper('obs_rsync.concurrency_guard' => \&_concurrency_guard);
        $app->helper('obs_rsync.guard'             => \&_guard);
        $app->helper('obs_rsync.lock'              => \&_lock);
        $app->helper('obs_rsync.unlock'            => \&_unlock);

        # Templates
        push @{$app->renderer->paths},
          Mojo::File->new(__FILE__)->dirname->child('ObsRsync')->child('templates')->to_string;

        $plugin_r->get('/obs_rsync/queue')->name('plugin_obs_rsync_queue')
          ->to('Plugin::ObsRsync::Controller::Gru#index');
        $plugin_r->post('/obs_rsync/#folder/runs')->name('plugin_obs_rsync_queue_run')
          ->to('Plugin::ObsRsync::Controller::Gru#run');
        $plugin_r->get('/obs_rsync/#folder/dirty_status')->name('plugin_obs_rsync_get_dirty_status')
          ->to('Plugin::ObsRsync::Controller::Gru#get_dirty_status');
        $plugin_r->post('/obs_rsync/#folder/dirty_status')->name('plugin_obs_rsync_update_dirty_status')
          ->to('Plugin::ObsRsync::Controller::Gru#update_dirty_status');
        $plugin_r->get('/obs_rsync/#folder/obs_version')->name('plugin_obs_rsync_get_obs_version')
          ->to('Plugin::ObsRsync::Controller::Gru#get_obs_version');
        $plugin_r->post('/obs_rsync/#folder/obs_version')->name('plugin_obs_rsync_update_obs_version')
          ->to('Plugin::ObsRsync::Controller::Gru#update_obs_version');

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
        $plugin_r->get('/obs_rsync/#folder/run_last')->name('plugin_obs_rsync_get_run_last')
          ->to('Plugin::ObsRsync::Controller::Folders#get_run_last');
        $plugin_r->post('/obs_rsync/#folder/run_last')->name('plugin_obs_rsync_forget_run_last')
          ->to('Plugin::ObsRsync::Controller::Folders#forget_run_last');
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
    my ($self, $url, $project) = @_;
    return undef unless $url;

    $url =~ s/%%PROJECT/$project/g;
    my $ua  = $self->{ua} ||= Mojo::UserAgent->new;
    my $res = $ua->get($url)->result;
    return undef unless $res->is_success;

    return _parse_obs_response_dirty($res);
}

sub _parse_obs_response_dirty {
    my ($res) = @_;

    my $results = $res->dom('result');
    return (undef, '') unless $results->size;

    for my $result ($results->each) {
        my $attributes = $result->attr;
        return (1, 'dirty') if exists $attributes->{dirty};
        next if ($attributes->{repository} // '') ne 'images';
        return (1, $attributes->{state} // '') if ($attributes->{state} // '') ne 'published';
    }
    return (0, 'published');
}

# _split_project_batch() splits name like 'projectname|batchname'
# and returns pair ('projectname', 'batchname')
# if $project doesn't have '|' character -
# returned pair is ($project, "")
sub _split_project_batch {
    my (undef, $project) = @_;
    my ($ret,  $batch)   = split(/\|/, $project, 2);
    $batch = "" unless $batch;
    return ($ret, $batch);
}

sub _get_batches {
    my ($c, $project, $only_first) = @_;
    my $home    = $c->obs_rsync->home;
    my $batches = Mojo::File->new($home, $project)->list({dir => 1})->grep(sub { -d $_ })->map('basename');
    return $batches->to_array() unless $only_first;
    return "" if !$batches->size;
    return $batches->to_array()->[0];
}

# _get_first_batch will attempt to split batch from input name
# and return it in pair with split project name
# otherwise it attempts to find first batch of project
# and returns it in pair with unaltered input
sub _get_first_batch {
    my ($c, $project) = @_;
    my $helper = $c->obs_rsync;
    my ($shortproj, $batch) = $helper->split_project_batch($project);
    return ($batch,                            $shortproj) if $batch;
    return ($helper->get_batches($project, 1), $project);
}

# This method is coupled with openqa-trigger-from-obs and returns
# string in format %y%m%d_%H%M%S, which corresponds to location
# used by openqa-trigger-from-obs to determine if any files changed
# or rsync can be skipped.
sub _get_run_last_info {
    my ($c, $project) = @_;
    my $helper = $c->obs_rsync;
    my $home   = $helper->home;
    (my $batch, $project) = $helper->get_first_batch($project);

    my $linkpath = Mojo::File->new($home, $project, $batch, '.run_last');
    my $folder;
    eval { $folder = readlink($linkpath) };
    return undef unless $folder;
    my %res;
    $res{dt}      = Mojo::File->new($folder)->basename =~ s/^.run_//r;
    $res{version} = _get_version_in_folder($linkpath);
    for my $f (qw(job_id)) {
        $res{$f} = _get_first_line(Mojo::File->new($linkpath, ".$f"));
    }
    return \%res;
}

sub _get_first_line {
    my ($file, $with_timestamp) = @_;
    open(my $fh, '<', $file) or return "";
    my $res = readline $fh;
    chomp $res;
    if ($with_timestamp) {
        my @stats = stat($fh);
        close $fh;
        return ($res, strftime('%Y-%m-%d %H:%M:%S %z', localtime($stats[9])));
    }
    close $fh;
    return $res;
}

sub _write_to_file {
    my ($file, $str) = @_;
    if (open(my $fh, '>', $file)) {
        print $fh $str;
        close $fh;
    }
}

# Dirty status file is updated from ObsRsync Gru tasks
sub _get_dirty_status {
    my ($c, $project) = @_;
    my $helper = $c->obs_rsync;
    # doesn't depend on batch, so just strip it out
    ($project, undef) = $helper->split_project_batch($project);
    my $home = $helper->home;
    my ($status, $when) = _get_first_line(Mojo::File->new($home, $project, $dirty_status_filename), 1);
    return "" unless $status;
    return "$status on $when";
}

# Obs version is parsed from files_iso.lst, which is updated from ObsRsync Gru tasks
sub _get_version_in_folder {
    my ($folder) = @_;
    open(my $fh, '<', Mojo::File->new($folder, $files_iso_filename)) or return "";
    my $version;
    while (my $row = <$fh>) {
        chomp $row;
        next unless $row;
        next if substr($row, 0, 1) eq "#";
        if ($row =~ m/Build((\d)+\.(\d)+(\.(\d)+)?)/ or $row =~ m/Snapshot((\d)+(\.(\d)+)*)/) {
            $version = $1;
            last;
        }
    }
    close $fh;
    return $version;
}

# Obs version is parsed from files_iso.lst, which is updated from ObsRsync Gru tasks
sub _get_obs_version {
    my ($c, $project) = @_;
    my $helper = $c->obs_rsync;
    my $home   = $helper->home;
    (my $batch, $project) = $helper->get_first_batch($project);

    return _get_version_in_folder(Mojo::File->new($home, $project, $batch));
}

sub _concurrency_guard {
    my $app = shift->app;
    return $app->minion->guard('obs_rsync_run_guard', $lock_timeout, {limit => $app->obs_rsync->concurrency});
}

sub _guard {
    my ($c, $project) = @_;
    return $c->app->minion->guard('obs_rsync_project_' . $project . '_lock', $lock_timeout);
}

sub _lock {
    my ($c, $project) = @_;
    return $c->app->minion->lock('obs_rsync_project_' . $project . '_lock', $lock_timeout);
}

sub _unlock {
    my ($c, $project) = @_;
    return $c->app->minion->unlock('obs_rsync_project_' . $project . '_lock');
}

sub _log_job_id {
    my ($c, $project, $job_id) = @_;
    my $home = $c->obs_rsync->home;
    return _write_to_file(Mojo::File->new($home, $project, '.job_id'), $job_id);
}

sub _log_failure {
    my ($c, $project, $job_id) = @_;
    my $home = $c->obs_rsync->home;
    return _write_to_file(Mojo::File->new($home, $project, '.last_failed_job_id'), $job_id);
}

sub _get_last_failed_job {
    my ($c, $project, $with_timestamp) = @_;
    my $home = $c->obs_rsync->home;
    return _get_first_line(Mojo::File->new($home, $project, '.last_failed_job_id'), $with_timestamp);
}

sub _check_and_render_error {
    my ($c,    @args)    = @_;
    my ($code, $message) = _check_error($c->obs_rsync->home, @args);
    $c->render(json => {error => $message}, status => $code) if $code;
    return $code;
}

sub _check_error {
    my ($home, $project, $subfolder, $filename) = @_;
    return (405, 'Home directory is not set') unless $home;
    return (405, 'Home directory not found')  unless -d $home;
    return (400, 'Project has invalid characters')   if $project   && $project   =~ m!/!;
    return (400, 'Subfolder has invalid characters') if $subfolder && $subfolder =~ m!/!;
    return (400, 'Filename has invalid characters')  if $filename  && $filename  =~ m!/!;

    ($project, my $batch) = _split_project_batch(undef, $project);
    return (404, "Invalid Project {$project}") if $project && !-d Mojo::File->new($home, $project);
    return (404, "Invalid Batch {$project|$batch}")
      if $project && $batch && !-d Mojo::File->new($home, $project, $batch);
    return 0;
}

1;
