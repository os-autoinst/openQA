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

my $home;
my $app;

sub init_obs_rsync {
    $home = shift;
    $app  = shift;
}

sub index {
    my $self   = shift;
    my $folder = $self->param('folder');
    return if $self->_check_and_render_error($folder);
    my $out
      = `find "$home" -mindepth 1 -maxdepth 1 -type d -exec basename {} \\; | grep -v test | grep -v __pycache__ | grep -v WebAPIPlugin | grep -v .git`;
    my @files = sort split(/\n/, $out);

    $self->_grep_and_stash_list(\@files, '[a-zA-Z]', 'folders');
    $self->render('ObsRsync_index');
}

sub folder {
    my $self   = shift;
    my $folder = $self->param('folder');
    return if $self->_check_and_render_error($folder);

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
    my $self   = shift;
    my $folder = $self->param('folder');
    return if $self->_check_and_render_error($folder);

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
    my $self      = shift;
    my $folder    = $self->param('folder');
    my $subfolder = $self->param('subfolder');
    return if $self->_check_and_render_error($folder, $subfolder);

    my $full = $home . '/' . $folder . '/' . $subfolder;
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
    my $self      = shift;
    my $folder    = $self->param('folder');
    my $subfolder = $self->param('subfolder');
    my $filename  = $self->param('filename');
    return if $self->_check_and_render_error($folder, $subfolder, $filename);

    my $full = $home . '/' . $folder;
    $full = $full . '/' . $subfolder if $subfolder;

    my $static = Mojolicious::Static->new;
    $static->paths([$full]);
    return $self->rendered if $static->serve($self, $filename);
}

sub run {
    my $self   = shift;
    my $folder = $self->param('folder');
    return if $self->_check_and_render_error($folder);

    my $cmd    = "bash '$home/rsync.sh' '$folder' 2>&1";
    my $out    = `$cmd`;
    my $rc     = $? >> 8;
    my $status = $rc ? 500 : 201;
    return $self->render(json => {output => $out, code => $rc}, status => $status);
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
    # return 401 unless ($self->is_user());
    # return 403 unless ($self->is_admin());
    return ("Home directory is not set", 405) unless $home;
    return ("Home directory not found",  405) unless -d $home;
    return "Project has invalid characters" if $project && CORE::index($project, '/') != -1;
    return "Subfolder has invalid characters" if ($subfolder && CORE::index($subfolder, '/') != -1);
    return "Filename has invalid characters"  if ($filename  && CORE::index($filename,  '/') != -1);

    print($project . "\n") if $project;

    return 404 unless !$project || -d $home . '/' . $project;

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
