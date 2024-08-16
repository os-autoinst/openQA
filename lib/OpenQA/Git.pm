# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later
package OpenQA::Git;

use Mojo::Base -base, -signatures;
use Mojo::Util 'trim';
use Cwd 'abs_path';
use OpenQA::Utils qw(run_cmd_with_log_return_error);
use Mojo::File;

has 'app';
has 'dir';
has 'user';

sub enabled ($self, $args = undef) {
    die 'no app assigned' unless my $app = $self->app;
    return ($app->config->{global}->{scm} || '') eq 'git';
}

sub config ($self, $args = undef) {
    die 'no app assigned' unless my $app = $self->app;
    return $app->config->{'scm git'};
}

sub _prepare_git_command ($self, $args = undef) {
    my $dir = $args->{dir} // $self->dir;
    if ($dir !~ /^\//) {
        my $absolute_path = abs_path($dir);
        $dir = $absolute_path if ($absolute_path);
    }
    return ('git', '-C', $dir);
}

sub _format_git_error ($self, $result, $error_message) {
    
    my $path = $self->dir;
    if ($result->{stderr} or $result->{stdout}) {
        $error_message .= "($path): " . $result->{stdout} . $result->{stderr};
    }
    return $error_message;
}

sub _validate_attributes ($self) {
    for my $mandatory_property (qw(app dir user)) {
        die "no $mandatory_property specified" unless $self->$mandatory_property();
    }
}

sub set_to_latest_master ($self, $args = undef) {
    $self->_validate_attributes;

    my @git = $self->_prepare_git_command($args);

    if (my $update_remote = $self->config->{update_remote}) {
        my $res = run_cmd_with_log_return_error([@git, 'remote', 'update', $update_remote]);
        return $self->_format_git_error($res, 'Unable to fetch from origin master') unless $res->{status};
    }

    if (my $update_branch = $self->config->{update_branch}) {
        if ($self->config->{do_cleanup} eq 'yes') {
            my $res = run_cmd_with_log_return_error([@git, 'reset', '--hard', 'HEAD']);
            return $self->_format_git_error($res, 'Unable to reset repository to HEAD') unless $res->{status};
        }
        my $res = run_cmd_with_log_return_error([@git, 'rebase', $update_branch]);
        return $self->_format_git_error($res, 'Unable to reset repository to origin/master') unless $res->{status};
    }

    return undef;
}

sub commit ($self, $args = undef) {
    $self->_validate_attributes;

    my @git = $self->_prepare_git_command($args);
    my @files;

    # stage changes
    for my $cmd (qw(add rm)) {
        next unless $args->{$cmd};
        push(@files, @{$args->{$cmd}});
        my $res = run_cmd_with_log_return_error([@git, $cmd, @{$args->{$cmd}}]);
        return $self->_format_git_error($res, "Unable to $cmd via Git") unless $res->{status};
    }

    # commit changes
    my $message = $args->{message};
    my $author = sprintf('--author=%s <%s>', $self->user->fullname, $self->user->email);
    my $res = run_cmd_with_log_return_error([@git, 'commit', '-q', '-m', $message, $author, @files]);
    return $self->_format_git_error($res, 'Unable to commit via Git') unless $res->{status};

    # push changes
    if (($self->config->{do_push} || '') eq 'yes') {
        $res = run_cmd_with_log_return_error([@git, 'push']);
        return $self->_format_git_error($res, 'Unable to push Git commit') unless $res->{status};
    }

    return undef;
}

# Moved functions from Clone.pm

sub get_current_branch ($self) {#
    my @git = $self->_prepare_git_command();
    my $r = run_cmd_with_log_return_error([@git, 'branch', '--show-current']);
    die "Error detecting current branch for : $r->{stderr}" unless $r->{status};
    return Mojo::Util::trim($r->{stdout});
}

sub _ssh_git_cmd ($self, $git_args) {
    return ['env', 'GIT_SSH_COMMAND="ssh -oBatchMode=yes"', 'git', @$git_args];
}

sub get_remote_default_branch ($self, $url) {
    my $r = run_cmd_with_log_return_error($self->_ssh_git_cmd(['ls-remote', '--symref', $url, 'HEAD']));
    die "Error detecting remote default branch name for '$url': $r->{stderr}"
      unless $r->{status} && $r->{stdout} =~ /refs\/heads\/(\S+)\s+HEAD/;
    return $1;
}

sub git_clone_url_to_path ($self, $url, $path) {  
    my $r = run_cmd_with_log_return_error($self->_ssh_git_cmd(['clone', $url, $path]));
    die "Failed to clone $url into '$path': $r->{stderr}" unless $r->{status};
}

sub git_get_origin_url ($self, $path) {
    my $r = run_cmd_with_log_return_error(['git', '-C', $path, 'remote', 'get-url', 'origin']);
    die "Failed to get origin url for '$path': $r->{stderr}" unless $r->{status};
    return Mojo::Util::trim($r->{stdout});
}

sub git_fetch ($self, $path, $branch_arg) {
    my $r = run_cmd_with_log_return_error($self->_ssh_git_cmd(['-C', $path, 'fetch', 'origin', $branch_arg]));
    die "Failed to fetch from '$branch_arg': $r->{stderr}" unless $r->{status};
}

sub git_reset_hard ($self, $path, $branch) {
    my $r = run_cmd_with_log_return_error(['git', '-C', $path, 'reset', '--hard', "origin/$branch"]);
    die "Failed to reset to 'origin/$branch': $r->{stderr}" unless $r->{status};
}

1;
