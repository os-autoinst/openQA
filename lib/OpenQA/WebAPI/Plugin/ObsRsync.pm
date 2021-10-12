# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Plugin::ObsRsync;
use Mojo::Base 'Mojolicious::Plugin';

use Mojo::File;
use Mojo::URL;
use Mojo::UserAgent;
use POSIX 'strftime';

use OpenQA::Log qw(log_error);

my $dirty_status_filename = '.dirty_status';
my $api_repo_filename = '.api_repo';
my $api_package_filename = '.api_package';
my $files_iso_filename = 'files_iso.lst';
my $files_media_filemask = qr/Media.*\.lst$/;

my $lock_timeout = 360000;

# register_common_routes adds the same routes for:
# non-privileged routes - will be accessible with curl without authentication
# ensure_operator - privileged routes for using in UI
# api_ensure_operator - privileged routes for API access
sub register_common_routes {
    my ($self, $r, $suffix) = @_;
    my $prefix = 'plugin_obs_rsync_';
    $prefix .= $suffix . '_' if $suffix;

    # These routes will be as well accessible without authorization!!
    $r->get('/obs_rsync/#alias/latest_test')->name($prefix . 'latest_test')
      ->to('Plugin::ObsRsync::Controller::Folders#test_result');
    $r->get('/obs_rsync/#alias/test_result')->name($prefix . 'test_result')
      ->to('Plugin::ObsRsync::Controller::Folders#test_result');
}

sub register {
    my ($self, $app, $config) = @_;
    my $plugin_r = $app->routes->find('ensure_operator');
    my $plugin_api_r = $app->routes->find('api_ensure_operator');

    if (!$plugin_r) {
        $app->log->error('Routes not configured, plugin ObsRsync will be disabled') unless $plugin_r;
    }
    else {
        $app->helper('obs_rsync.home' => sub { shift->app->config->{obs_rsync}->{home} });
        $app->helper('obs_rsync.concurrency' => sub { shift->app->config->{obs_rsync}->{concurrency} });
        $app->helper('obs_rsync.retry_interval' => sub { shift->app->config->{obs_rsync}->{retry_interval} });
        $app->helper('obs_rsync.retry_max_count' => sub { shift->app->config->{obs_rsync}->{retry_max_count} });
        $app->helper('obs_rsync.queue_limit' => sub { shift->app->config->{obs_rsync}->{queue_limit} });
        $app->helper('obs_rsync.project_status_url' => sub { shift->app->config->{obs_rsync}->{project_status_url} });
        $app->helper(
            'obs_rsync.is_status_dirty' => sub {
                my ($c, $alias, $trace) = @_;
                my $helper = $c->obs_rsync;
                my ($project, undef) = $helper->split_alias($alias);
                my $repo = $helper->get_api_repo($alias);
                my $url = $helper->get_api_dirty_status_url($project);
                return undef unless $url;
                my @res = $self->_is_obs_project_status_dirty($url, $project, $repo);
                if ($trace && scalar @res > 1 && $res[1]) {
                    # ignore potential errors because we use this only for cosmetic rendering
                    open(my $fh, '>', Mojo::File->new($c->obs_rsync->home, $project, $dirty_status_filename))
                      or return $res[0];
                    print $fh $res[1];
                    close $fh;
                }
                return $res[0];
            });
        $app->helper('obs_rsync.split_alias' => \&_split_alias);
        $app->helper('obs_rsync.split_repo' => \&_split_repo);
        $app->helper('obs_rsync.for_every_batch' => \&_for_every_batch);
        $app->helper('obs_rsync.get_batches' => \&_get_batches);
        $app->helper('obs_rsync.get_first_batch' => \&_get_first_batch);
        $app->helper('obs_rsync.get_last_test_id' => \&_get_last_test_id);
        $app->helper('obs_rsync.get_version_test_id' => \&_get_version_test_id);
        $app->helper('obs_rsync.get_test_result' => \&_get_test_result);
        $app->helper('obs_rsync.get_run_last_info' => \&_get_run_last_info);
        $app->helper(
            'obs_rsync.get_fail_last_info' => sub {
                my ($c, $project) = @_;
                return _get_last_failed_job($c, $project, 1);
            });
        $app->helper('obs_rsync.get_api_repo' => \&_get_api_repo);
        $app->helper('obs_rsync.get_api_package' => \&_get_api_package);
        $app->helper('obs_rsync.get_api_dirty_status_url' => \&_get_api_dirty_status_url);
        $app->helper('obs_rsync.get_dirty_status' => \&_get_dirty_status);
        $app->helper('obs_rsync.get_obs_builds_text' => \&_get_obs_builds_text);
        $app->helper('obs_rsync.check_and_render_error' => \&_check_and_render_error);

        $app->helper('obs_rsync.log_job_id' => \&_log_job_id);
        $app->helper('obs_rsync.log_failure' => \&_log_failure);
        $app->helper('obs_rsync.concurrency_guard' => \&_concurrency_guard);
        $app->helper('obs_rsync.guard' => \&_guard);
        $app->helper('obs_rsync.lock' => \&_lock);
        $app->helper('obs_rsync.unlock' => \&_unlock);

        # Templates
        push @{$app->renderer->paths},
          Mojo::File->new(__FILE__)->dirname->child('ObsRsync')->child('templates')->to_string;

        # terminology:
        # * project - Obs Project name alone, e.g. 'openSUSE:Factory:ToTest'
# * batch - abstraction used by openqa-trigger-from-obs to split actions, needed to be taken when Obs Project is ready for testing,
        # e.g. 'base, 'jeos', 'migration'.
        # * alias - Obs Project name alone or with corresponding batch concatenated with '|': 'projectname|batchname'
        # e.g. 'openSUSE:Factory:ToTest|base', 'openSUSE:Factory:ToTest|microos', 'openSUSE:Factory:ToTest|jeos'
    # * subfolder - folder, containing artifacts from paricular synch actions. Most often if form `.run_YYYYMMDDhhmmss`.
        #
     # routes which have parameter #alias, can be called for simple project, for batched project or for particular batch
        # routes which have parameter #project, can not be called for single batch
        $plugin_r->get('/obs_rsync/queue')->name('plugin_obs_rsync_queue')
          ->to('Plugin::ObsRsync::Controller::Gru#index');
        $plugin_r->post('/obs_rsync/#project/runs')->name('plugin_obs_rsync_queue_run')
          ->to('Plugin::ObsRsync::Controller::Gru#run');
        $plugin_r->get('/obs_rsync/#project/dirty_status')->name('plugin_obs_rsync_get_dirty_status')
          ->to('Plugin::ObsRsync::Controller::Gru#get_dirty_status');
        $plugin_r->post('/obs_rsync/#project/dirty_status')->name('plugin_obs_rsync_update_dirty_status')
          ->to('Plugin::ObsRsync::Controller::Gru#update_dirty_status');
        $plugin_r->get('/obs_rsync/#alias/obs_builds_text')->name('plugin_obs_rsync_get_builds_text')
          ->to('Plugin::ObsRsync::Controller::Gru#get_obs_builds_text');
        $plugin_r->post('/obs_rsync/#alias/obs_builds_text')->name('plugin_obs_rsync_update_builds_text')
          ->to('Plugin::ObsRsync::Controller::Gru#update_obs_builds_text');

        $plugin_r->get('/obs_rsync/#alias/runs/#subfolder/download/#filename')->name('plugin_obs_rsync_download_file')
          ->to('Plugin::ObsRsync::Controller::Folders#download_file');
        $plugin_r->get('/obs_rsync/#alias/runs/#subfolder')->name('plugin_obs_rsync_run')
          ->to('Plugin::ObsRsync::Controller::Folders#run');
        $plugin_r->get('/obs_rsync/#alias/runs')->name('plugin_obs_rsync_runs')
          ->to('Plugin::ObsRsync::Controller::Folders#runs');
        $plugin_r->get('/obs_rsync/#alias')->name('plugin_obs_rsync_folder')
          ->to('Plugin::ObsRsync::Controller::Folders#folder');
        $plugin_r->get('/obs_rsync/')->name('plugin_obs_rsync_index')
          ->to('Plugin::ObsRsync::Controller::Folders#index');
        $plugin_r->get('/obs_rsync_list')->name('plugin_obs_rsync_list')
          ->to('Plugin::ObsRsync::Controller::Folders#list');
        $plugin_r->get('/obs_rsync/#alias/run_last')->name('plugin_obs_rsync_get_run_last')
          ->to('Plugin::ObsRsync::Controller::Folders#get_run_last');
        $plugin_r->post('/obs_rsync/#alias/run_last')->name('plugin_obs_rsync_forget_run_last')
          ->to('Plugin::ObsRsync::Controller::Folders#forget_run_last');

        $self->register_common_routes($plugin_r);
        # we create the common routes without authentication as well
        $self->register_common_routes($app->routes(), 'public');

        $app->config->{plugin_links}{operator}{'OBS Sync'} = 'plugin_obs_rsync_index';
    }

    if (!$plugin_api_r) {
        $app->log->error('API routes not configured, plugin ObsRsync will not have API configured') unless $plugin_r;
    }
    else {
        $plugin_api_r->get('/obs_rsync')->name('plugin_obs_rsync_api_list')
          ->to('Plugin::ObsRsync::Controller::Folders#list');
        $plugin_api_r->put('/obs_rsync/#project/runs')->name('plugin_obs_rsync_api_run')
          ->to('Plugin::ObsRsync::Controller::Gru#run');

        $self->register_common_routes($plugin_api_r, 'api');
    }

    $app->plugin('OpenQA::WebAPI::Plugin::ObsRsync::Task');
}

# try to determine whether project is dirty
# undef means status is unknown
sub _is_obs_project_status_dirty {
    my ($self, $url, $project, $repo) = @_;
    return undef unless $url;

    my $ua = $self->{ua} ||= Mojo::UserAgent->new;
    my $res = $ua->get($url)->result;
    return undef unless $res->is_success;
    return _parse_obs_response_dirty($res, $repo);
}

sub _parse_obs_response_dirty {
    my ($res, $repo) = @_;
    $repo = 'images' unless $repo;

    my $results = $res->dom('result');
    return (undef, '') unless $results->size;

    my $retstate = '';
    for my $result ($results->each) {
        my $attributes = $result->attr;
        return (1, 'dirty') if exists $attributes->{dirty};
        next if ($attributes->{repository} // '') ne $repo;
        my $state = $attributes->{state} // '';
        # values containing 'published' are not dirty: ('published', 'unpublished')
        return (1, $state) if $state && index($state, 'published') == -1;
        $retstate = $state if $state;
    }
    return (0, $retstate);
}

# _split_repo() splits name like 'projectname::repo'
# and returns pair ('projectname', 'repo')
# if input doesn't have '::' character -
# returned pair is ($project, '')
sub _split_repo {
    my (undef, $alias) = @_;
    my ($project, $repo) = split(/::/, $alias, 2);
    $repo = '' unless $repo;
    return ($project, $repo);
}

# _split_alias() splits name like 'projectname|batchname'
# and returns pair ('projectname', 'batchname')
# if input doesn't have '|' character -
# returned pair is ($project, '')
sub _split_alias {
    my (undef, $alias) = @_;
    my ($project, $batch) = split(/\|/, $alias, 2);
    $batch = '' unless $batch;
    return ($project, $batch);
}

sub _get_batches {
    my ($c, $project, $only_first) = @_;
    my $home = $c->obs_rsync->home;
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
    my ($c, $alias) = @_;
    my $helper = $c->obs_rsync;
    my ($project, $batch) = $helper->split_alias($alias);
    return ($batch, $project) if $batch;
    return ($helper->get_batches($project, 1), $project);
}

# _get_last_test_id is coupled with openqa-trigger-from-obs and tries to
# extract the job id returned by `job post` command as noted in openqa.cmd.log
# returns empty string when log file doesn't exists or pattern didn't match
# throws exception if OS error occurs
sub _get_last_test_id {
    my ($c, $alias) = @_;
    my $home = $c->obs_rsync->home;
    # don't call get_first_batch: test info is not supported for batches yet

    return _read_test_id(Mojo::File->new($home, $alias, '.run_last'));
}

sub _read_test_id {
    my $cmdlog = shift->child('openqa.cmd.log');
    return '' unless -f $cmdlog;
    my $fh = $cmdlog->open('<');
    my $res = '';
    while (my $line = <$fh>) {
        if ($line =~ /\{ id =\> ([1-9][0-9]*) \}/) {
            $res = $1;
            last;
        }
    }
    close $fh;
    return $res;
}

sub _get_test_result {
    my ($c, $id) = @_;
    return 'unknown' unless my $job = $c->schema->resultset("Jobs")->find($id);
    return $job->result;
}

sub _get_version_test_id {
    my ($c, $project, $version) = @_;
    return undef unless $version;
    my $home = $c->obs_rsync->home;
    my $runs = Mojo::File->new($home, $project)->list({dir => 1, hidden => 1})->map('basename')->grep(qr/\.run_.*/)
      ->grep(qr/_$version$/)->sort(sub { $b cmp $a })->to_array;
    return undef unless $runs && @$runs;
    return _read_test_id(Mojo::File->new($home, $project, $runs->[0]));
}

# This method is coupled with openqa-trigger-from-obs and returns
# string in format %y%m%d_%H%M%S, which corresponds to location
# used by openqa-trigger-from-obs to determine if any files changed
# or rsync can be skipped.
sub _get_run_last_info {
    my ($c, $alias) = @_;
    my $helper = $c->obs_rsync;
    my $home = $helper->home;
    my ($batch, $project) = $helper->get_first_batch($alias);

    my $linkpath = Mojo::File->new($home, $project, $batch, '.run_last');

    my $folder;
    unless ($folder = readlink($linkpath)) {
        log_error("Cannot read symbolic link ($linkpath): $!");
        return undef;
    }

    my %res;
    $res{dt} = Mojo::File->new($folder)->basename =~ s/^.run_//r;
    $res{builds} = $helper->get_obs_builds_text($alias, 1);
    for my $f (qw(job_id)) {
        $res{$f} = _get_first_line(Mojo::File->new($linkpath, ".$f"));
    }
    return \%res;
}

sub _get_first_line {
    my ($file, $with_timestamp) = @_;
    open(my $fh, '<', $file) or return "";
    my $res = readline $fh;
    return "" unless $res;
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
    my ($c, $alias) = @_;
    my $helper = $c->obs_rsync;
    # doesn't depend on batch, so just strip it out
    my ($project, undef) = $helper->split_alias($alias);
    my $home = $helper->home;
    my ($status, $when) = _get_first_line(Mojo::File->new($home, $project, $dirty_status_filename), 1);
    return "" unless $status;
    return "$status on $when";
}

# Which repo on OBS should trigger sync
sub _get_api_repo {
    my ($c, $alias) = @_;
    my $helper = $c->obs_rsync;
    # doesn't depend on batch, so just strip it out
    my ($project, undef) = $helper->split_alias($alias);
    ($project, my $repo) = $helper->split_repo($project);
    return $repo if $repo;
    my $home = $helper->home;
    my $ret = _get_first_line(Mojo::File->new($home, $project, $api_repo_filename));
    return $ret if $ret;
    return "images";
}

# Which package on OBS should be checked for being published on obs
sub _get_api_package {
    my ($c, $alias) = @_;
    my $helper = $c->obs_rsync;
    # doesn't depend on batch, so just strip it out
    my ($project, undef) = $helper->split_alias($alias);
    my $home = $helper->home;
    my $api_package_file = Mojo::File->new($home, $project, $api_package_filename);
    return '000product' unless -f $api_package_file;
    return _get_first_line($api_package_file);
}

# Build url to check dirty status for project
sub _get_api_dirty_status_url {
    my ($c, $project) = @_;
    my $helper = $c->obs_rsync;
    my $url_str = $helper->project_status_url;
    return "" unless $url_str;
    # need split eventual batch and repository in project name
    ($project, undef) = $helper->split_alias($project);
    my $package = $helper->get_api_package($project);
    ($project, undef) = $helper->split_repo($project);
    $url_str =~ s/%%PROJECT/$project/g;
    my $url = Mojo::URL->new($url_str);
    $url->query({package => $package}) if $package;
    return $url->to_string;
}

sub _get_builds_in_file {
    my ($file, $seen) = @_;
    open(my $fh, '<', $file) or return undef;
    while (my $row = <$fh>) {
        chomp $row;
        next unless $row;
        next unless ($row =~ m/(Build|Snapshot)((\d)+(\.(\d)+)*)/);
        my $build = $2;
        $seen->{$build} = 1;
    }
    close $fh;
    return undef;
}

# Obs version is parsed from files_iso.lst for iso and hdd
# and from Media*.lst, for repositories
# these files are updated from ObsRsync Gru tasks
sub _get_builds_in_folder {
    my ($folder) = @_;
    my %seen;
    _get_builds_in_file(Mojo::File->new($folder, $files_iso_filename), \%seen);
    Mojo::File->new($folder)->list()->grep($files_media_filemask)->each(
        sub {
            _get_builds_in_file(shift->to_string, \%seen);
        });
    return sort { $b cmp $a } keys %seen;
}

# Obs builds are parsed from files_iso.lst, which is updated from ObsRsync Gru tasks
sub _get_obs_builds_text {
    my ($c, $alias, $last) = @_;
    my $helper = $c->obs_rsync;
    my $home = $helper->home;
    my $subfolder = $last ? '.run_last' : '';
    my %seen;
    my $sub = sub {
        my ($project, $batch) = @_;
        my @builds = _get_builds_in_folder(Mojo::File->new($home, $project, $batch, $subfolder));
        for my $build (@builds) {
            $seen{$build} = 1 if $build;
        }
        return undef;
    };
    $helper->for_every_batch($alias, $sub);

    my @builds = sort { $b cmp $a } keys %seen;
    return "No data" unless @builds;
    return join ', ', @builds;
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
    my ($c, @args) = @_;
    my ($code, $message) = _check_error($c->obs_rsync->home, @args);
    $c->render(json => {error => $message}, status => $code) if $code;
    return $code;
}

sub _check_error {
    my ($home, $alias, $subfolder, $filename) = @_;
    return (405, 'Home directory is not set') unless $home;
    return (405, 'Home directory not found') unless -d $home;
    return (400, 'Project has invalid characters') if $alias && $alias =~ m!/!;
    return (400, 'Subfolder has invalid characters') if $subfolder && $subfolder =~ m!/!;
    return (400, 'Filename has invalid characters') if $filename && $filename =~ m!/!;

    my ($project, $batch) = _split_alias(undef, $alias);
    return (404, "Invalid Project {$project}") if $project && !-d Mojo::File->new($home, $project);
    return (404, "Invalid Batch {$project|$batch}")
      if $project && $batch && !-d Mojo::File->new($home, $project, $batch);
    return 0;
}

sub _for_every_batch {
    my ($c, $alias, $sub) = @_;
    my $helper = $c->obs_rsync;
    my ($project, $batch) = $helper->split_alias($alias);

    # Three cases possible when $sub() must be called:
    # for this single batch alone ($thisbatch != undef)
    # for a regular project without batches (!@$batches)
    # for every batch of a project with batches
    return $sub->($project, $batch) if $batch;
    my $batches = $helper->get_batches($project);
    return $sub->($project, '') unless @$batches;

    my @ret;
    for my $batch (@$batches) {
        @ret = $sub->($project, $batch);
        return @ret if @ret && $ret[0];
    }
    return @ret;
}

1;
