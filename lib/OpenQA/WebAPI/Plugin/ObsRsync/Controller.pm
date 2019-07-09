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

package OpenQA::WebAPI::Plugin::ObsRsync::Controller;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::File;
use File::Basename;

sub _home {
    my $self = shift;
    $self->app->config->{obs_rsync}->{home};
}

sub index {
    my $self   = shift;
    my $folder = $self->param('folder');
    return if $self->_check_and_render_error($folder);
    my $files = Mojo::File->new($self->_home)->list({dir => 1})->map(sub { $_->basename })
      ->grep(qr/^(?!test|WebAPIPlugin|__pycache__)/)->to_array;

    my @files = grep -d Mojo::File->new($self->_home, $_), @$files;

    $self->render('ObsRsync_index', folders => \@files);
}

sub folder {
    my $self   = shift;
    my $folder = $self->param('folder');
    return if $self->_check_and_render_error($folder);

    my $full        = $self->_home;
    my $obs_project = $folder;
    my $files       = Mojo::File->new($full, $obs_project, '.run_last')->list({dir => 1})->map(sub { $_->basename });

    $self->render(
        'ObsRsync_folder',
        obs_project     => $obs_project,
        lst_files       => $files->grep(qr/files_.*\.lst/)->to_array,
        read_files_sh   => $files->grep(qr/read_files\.sh/)->join(),
        rsync_commands  => $files->grep(qr/rsync_.*\.cmd/)->to_array,
        rsync_sh        => $files->grep(qr/print_rsync.*\.sh/)->to_array,
        openqa_commands => $files->grep(qr/openqa\.cmd/)->join(),
        openqa_sh       => $files->grep(qr/print_openqa\.sh/)->join());
}

sub logs {
    my $self   = shift;
    my $folder = $self->param('folder');
    return if $self->_check_and_render_error($folder);

    my $full = Mojo::File->new($self->_home, $folder);
    my $files
      = $full->list({dir => 1, hidden => 1})->map(sub { $_->basename })->grep(qr/\.run_.*/)->sort(sub { $b cmp $a })
      ->to_array;
    $self->render('ObsRsync_logs', folder => $folder, full => $full->to_string, subfolders => $files);
}

sub logfiles {
    my $self      = shift;
    my $folder    = $self->param('folder');
    my $subfolder = $self->param('subfolder');
    return if $self->_check_and_render_error($folder, $subfolder);

    my $full  = Mojo::File->new($self->_home, $folder, $subfolder);
    my $files = $full->list({dir => 1})->map(sub { $_->basename })->sort->to_array;
    $self->render(
        'ObsRsync_logfiles',
        folder    => $folder,
        subfolder => $subfolder,
        full      => $full->to_string,
        files     => $files
    );
}

sub download_file {
    my $self      = shift;
    my $folder    = $self->param('folder');
    my $subfolder = $self->param('subfolder');
    my $filename  = $self->param('filename');
    return if $self->_check_and_render_error($folder, $subfolder, $filename);

    my $full = $self->_home . '/' . $folder;
    $full = $full . '/' . $subfolder if $subfolder;
    $self->reply->file("$full/$filename");
}

sub run {
    my $self   = shift;
    my $folder = $self->param('folder');
    return if $self->_check_and_render_error($folder);

    my $cmd    = "bash '" . $self->_home . "/rsync.sh' '$folder' 2>&1";
    my $out    = `$cmd`;
    my $rc     = $? >> 8;
    my $status = $rc ? 500 : 201;
    return $self->render(json => {output => $out, code => $rc}, status => $status);
}

sub _grep_and_stash_scalar {
    my ($self, $files, $mask, $var) = @_;
    my $r = "";
    my @r = grep /$mask/, @$files;
    if (@r) {
        $r = $r[0];
    }
    $self->stash($var, $r);
}

sub _grep_and_stash_list {
    my ($self, $files, $mask, $var) = @_;
    my @r = grep /$mask/, @$files;
    $self->stash($var, \@r);
}

sub _check_and_render_error {
    my ($res, $code) = _check_error(@_);
    shift->_render_error($res, $code) if $res;
    return $res;
}

sub _check_error {
    my $self      = shift;
    my $project   = shift;
    my $subfolder = shift;
    my $filename  = shift;
    return ("Home directory is not set", 405) unless $self->_home;
    return ("Home directory not found",  405) unless -d $self->_home;
    return "Project has invalid characters" if $project && CORE::index($project, '/') != -1;
    return "Subfolder has invalid characters" if ($subfolder && CORE::index($subfolder, '/') != -1);
    return "Filename has invalid characters"  if ($filename  && CORE::index($filename,  '/') != -1);

    return 404 unless !$project || -d $self->_home . '/' . $project;

    return 0;
}

sub _render_error {
    my $self    = shift;
    my $message = shift;
    my $code    = shift;

    return $self->render(status => $message) if (($message + 0) eq $message);
    return $self->render(json => {error => $message}, status => $code) if ($code);
    return $self->render(json => {error => $message}, status => 400);
}


1;
