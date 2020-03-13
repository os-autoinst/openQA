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
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::WebAPI::Plugin::ObsRsync::Controller::Folders;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::File;
use POSIX 'strftime';

sub index {
    my ($self, $obs_project, $folders) = @_;
    my $helper = $self->obs_rsync;
    my %folder_info_by_name;
    if (!$folders) {
        $folders
          = Mojo::File->new($helper->home, $obs_project // '')->list({dir => 1})->grep(sub { -d $_ })->map('basename')
          ->to_array;
        @$folders = grep { !/^(t|profiles|script|xml)$/ } @$folders;
    }

    for my $folder (@$folders) {
        my $alias = $folder;
        $alias = "$obs_project|$folder" if $obs_project;
        my $run_last_info = $helper->get_run_last_info($alias);
        my ($fail_last_job_id, $fail_last_when) = $helper->get_fail_last_info($alias);
        my $dirty_status = $helper->get_dirty_status($obs_project // $folder);
        my $api_repo     = $helper->get_api_repo($obs_project     // $folder);
        $dirty_status = "$dirty_status ($api_repo)" if $api_repo ne "images";
        $folder_info_by_name{$folder} = {
            run_last         => $run_last_info->{dt},
            run_last_builds  => $run_last_info->{builds},
            run_last_job_id  => $run_last_info->{job_id},
            fail_last_when   => $fail_last_when,
            fail_last_job_id => $fail_last_job_id,
            dirty_status     => $dirty_status
        };
    }

    if (!$obs_project) {
        my $running_jobs = $self->app->minion->backend->list_jobs(0, undef,
            {tasks => ['obs_rsync_run'], states => ['active', 'inactive']});

        for my $job (@{$running_jobs->{jobs}}) {
            my $args = $job->{args};
            $args = $args->[0] if (ref $args eq 'ARRAY' && scalar(@$args) == 1);

            next unless (ref $args eq 'HASH' && scalar(%$args) == 1 && $args->{project});
            my $project = $args->{project};
            next unless exists $folder_info_by_name{$project};
            $folder_info_by_name{$project}->{state} = $job->{state};
            my $created_at = $job->{created};
            if ($created_at) {
                $created_at = strftime('%Y-%m-%d %H:%M:%S %z', localtime($created_at));
                $folder_info_by_name{$project}->{created} = $created_at;
            }
        }
    }
    $self->render('ObsRsync_index', folder_info_by_name => \%folder_info_by_name, project => $obs_project);
}

sub folder {
    my $self   = shift;
    my $alias  = $self->param('alias');
    my $helper = $self->obs_rsync;
    return undef if $helper->check_and_render_error($alias);
    my $full = $helper->home;
    my ($project, $batch) = $helper->split_alias($alias);

    # if project has batches - redirect to index route to show the batches
    if (!$batch) {
        my $batches = $helper->get_batches($project);
        return $self->index($project, $batches) if ref $batches eq 'ARRAY' && @$batches;
    }
    my $files = Mojo::File->new($full, $project, $batch, '.run_last')->list({dir => 1})->map('basename');

    $self->render(
        'ObsRsync_folder',
        alias           => $alias,
        project         => $project,
        batch           => $batch,
        lst_files       => $files->grep(qr/files_.*\.lst/)->to_array,
        read_files_sh   => $files->grep(qr/read_files\.sh/)->join(),
        rsync_commands  => $files->grep(qr/rsync_.*\.cmd/)->to_array,
        rsync_sh        => $files->grep(qr/print_rsync.*\.sh/)->to_array,
        openqa_commands => $files->grep(qr/openqa\.cmd/)->to_array,
        openqa_sh       => $files->grep(qr/print_openqa\.sh/)->join());
}

sub runs {
    my $self   = shift;
    my $alias  = $self->param('alias');
    my $helper = $self->obs_rsync;
    return undef if $helper->check_and_render_error($alias);
    my ($project, $batch) = $helper->split_alias($alias);

    my $full = Mojo::File->new($helper->home, $project, $batch);
    my $files
      = $full->list({dir => 1, hidden => 1})->map('basename')->grep(qr/\.run_.*/)->sort(sub { $b cmp $a })->to_array;
    $self->render('ObsRsync_logs', alias => $alias, full => $full->to_string, subfolders => $files);
}

sub run {
    my $self      = shift;
    my $alias     = $self->param('alias');
    my $subfolder = $self->param('subfolder');
    my $helper    = $self->obs_rsync;
    return undef if $helper->check_and_render_error($alias, $subfolder);
    my ($project, $batch) = $helper->split_alias($alias);

    my $full  = Mojo::File->new($helper->home, $project, $batch, $subfolder);
    my $files = $full->list->map('basename')->sort->to_array;
    $self->render(
        'ObsRsync_logfiles',
        alias     => $alias,
        subfolder => $subfolder,
        full      => $full->to_string,
        files     => $files
    );
}

sub download_file {
    my $self      = shift;
    my $alias     = $self->param('alias');
    my $subfolder = $self->param('subfolder');
    my $filename  = $self->param('filename');
    my $helper    = $self->obs_rsync;
    return undef if $helper->check_and_render_error($alias, $subfolder, $filename);
    my ($project, $batch) = $helper->split_alias($alias);

    my $full = Mojo::File->new($helper->home, $project, $batch, $subfolder);
    $self->res->headers->content_type('text/plain');
    $self->reply->file($full->child($filename));
}

sub get_run_last {
    my $self   = shift;
    my $alias  = $self->param('alias');
    my $helper = $self->obs_rsync;
    return undef if $helper->check_and_render_error($alias);

    my $run_last_info = $helper->get_run_last_info($alias);
    my $run_last      = "";
    $run_last = $run_last_info->{dt} if (defined $run_last_info && defined $run_last_info->{dt});

    return $self->render(json => {message => $run_last}, status => 200);
}

sub forget_run_last {
    my $self   = shift;
    my $alias  = $self->param('alias');
    my $helper = $self->obs_rsync;
    return undef if $helper->check_and_render_error($alias);
    my $app = $self->app;
    my ($batch, $project) = $helper->get_first_batch($alias);

    my $dest = Mojo::File->new($helper->home, $project, $batch, '.run_last');
    -l $dest or return $self->render(json => {message => '.run_last link not found'}, status => 404);

    my $project_lock = Mojo::File->new($helper->home, $project, 'rsync.lock');
    -f $project_lock and return $self->render(json => {message => 'Project lock exists'}, status => 423);

    if (unlink($dest)) {
        return $self->render(json => {message => 'success'}, status => 200);
    }
    return $self->render(json => {message => "error $!"}, status => 500);
}

1;
