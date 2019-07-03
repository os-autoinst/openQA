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
use File::Basename;
use Mojo::Template;

my $home;
my $app;

sub init_obs_rsync {
    $home = shift;
    $app  = shift;
}

sub index {
    my $self = shift;
    $home or return $self->_error('Not configured');
    -d $home or return $self->_error('Wrong home');
    my $out
      = `find "$home" -mindepth 1 -maxdepth 1 -type d -exec basename {} \\; | grep -v test | grep -v __pycache__ | grep -v WebAPIPlugin | grep -v .git`;
    my @files = sort split(/\n/, $out);

    $self->_grep_and_stash_list(\@files, '[a-zA-Z]', 'folders');
    $self->render('ObsRsync_index');
}

sub folder {
    my $self = shift;
    $home or return $self->_error('Not configured');
    -d $home or return $self->_error('Wrong home');

    my $folder      = $self->param('folder');
    my $full        = $home;
    my $obs_project = $folder;
    $full = $full . '/' . $obs_project;
    my $last_run = $full . '/.run_last';
    my @files;
    if (-d $last_run) {
        if (opendir my $dirh, $last_run) {
            @files = sort readdir $dirh;
            closedir $dirh;
        }
    }
    $self->_stash_files(\@files);
    $self->stash('obs_project', $obs_project);
    $self->render('ObsRsync_folder');
}

sub logs {
    my ($self) = @_;
    $home or return _error('Not configured');
    -d $home or return $self->_error('Wrong home');

    my $folder = $self->param('folder');
    if (CORE::index($folder, '/') != -1 || !$folder) {
        return _error('Incorrect name');
    }

    my $full = $home . '/' . $folder;
    opendir my $dirh, $full or return _error("Cannot open directory {$full} : $!");
    my @files = sort { $b cmp $a } readdir $dirh;
    closedir $dirh;
    $self->_grep_and_stash_list(\@files, '.run_.*', 'subfolders');
    $self->stash('folder', $folder);
    $self->stash('full',   $full);
    $self->render('ObsRsync_logs');
}

sub logfiles {
    my ($self) = @_;
    -d $home or return $self->_error('Wrong home');

    my $folder = $self->param('folder');
    if (CORE::index($folder, '/') != -1 || !$folder) {
        return $self->render(json => {error => 'Incorrect name'}, status => 400);
    }
    my $subfolder = $self->param('subfolder');
    my $full      = $home . '/' . $folder . '/' . $subfolder;
    if (!-d $full && -s $full) {
        return $self->download_file();
    }
    if (CORE::index($subfolder, '/') != -1) {
        return $self->render(json => {error => 'Incorrect subfolder name'}, status => 400);
    }
    opendir my $dirh, "$full" or die "Cannot open directory {$full}: $!";
    my @files = sort { $b cmp $a } readdir $dirh;
    closedir $dirh;
    $self->_grep_and_stash_list(\@files, '[a-z]', 'files');
    $self->stash('folder',    $folder);
    $self->stash('full',      $full);
    $self->stash('subfolder', $subfolder);
    $self->render('ObsRsync_logfiles');
}

sub download_file {
    my ($self) = @_;
    # return if (!$self->is_admin());
    my $folder = $self->param('folder');
    if (CORE::index($folder, '/') != -1 || !$folder) {
        return $self->render(json => {error => 'Incorrect name'}, status => 404);
    }
    my $subfolder = $self->param('subfolder');
    if (CORE::index($subfolder, '/') != -1) {
        return $self->render(json => {error => 'Incorrect subfolder name'}, status => 404);
    }
    my $filename = $self->param('filename');
    if ($filename && CORE::index($filename, '/') != -1) {
        return $self->render(json => {error => 'Incorrect file name'}, status => 404);
    }
    my $full = $home . '/' . $folder;
    $full = $full . '/' . $subfolder if $subfolder;

    my $static = Mojolicious::Static->new;
    $static->paths([$full]);
    return $self->rendered if $static->serve($self, $filename);
}

sub _grep_and_stash_scalar {
    my ($self, $files, $mask, $var) = @_;
    my $r = "";
    my @r = grep(/$mask/, @$files);
    if (@r) {
        $r = $r[0];
    }
    $self->stash($var, $r);
}

sub _grep_and_stash_list {
    my ($self, $files, $mask, $var) = @_;
    my @r = grep(/$mask/, @$files);
    $self->stash($var, \@r);
}

sub _stash_files {
    my ($self, $files) = @_;
    $self->_grep_and_stash_list($files, 'files_.*\.lst', 'lst_files');
    $self->_grep_and_stash_scalar($files, 'read_files\.sh', 'read_files_sh');

    $self->_grep_and_stash_list($files, 'rsync_.*\.cmd',      'rsync_commands');
    $self->_grep_and_stash_list($files, 'print_rsync_.*\.sh', 'rsync_sh');

    $self->_grep_and_stash_scalar($files, 'openqa.cmd',       'openqa_commands');
    $self->_grep_and_stash_scalar($files, 'print_openqa\.sh', 'openqa_sh');
}

sub _error {
    my $self    = shift;
    my $message = shift;

    $self->render(json => {error => $message}, status => 404);
}


1;
