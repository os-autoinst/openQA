# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Git;

use Mojo::Base -base, -signatures;
use Mojo::Util 'trim';
use Cwd 'abs_path';
use OpenQA::Utils qw(run_cmd_with_log_return_error);

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

sub _validate_attributes ($self) {
    for my $mandatory_property (qw(app dir user)) {
        die "no $mandatory_property specified" unless $self->$mandatory_property();
    }
}

sub _run_cmd ($self, $args, $options = {}) {
    my $include_git_path = $options->{include_git_path} // 1;
    my $ssh_batchmode = $options->{ssh_batchmode} // 0;
    my @cmd;
    push @cmd, 'env', 'GIT_SSH_COMMAND=ssh -oBatchMode=yes' if $ssh_batchmode;
    push @cmd, $self->_prepare_git_command($include_git_path), @$args;

    my $result = run_cmd_with_log_return_error(\@cmd);
    $self->app->log->error("Git command failed: @cmd - Error: $result->{stderr}") unless $result->{status};
    return $result;
}

sub _prepare_git_command ($self, $include_git_path) {
    return 'git' unless $include_git_path;
    my $dir = $self->dir;
    die 'no valid directory was found during git preparation' unless $dir;
    if ($dir !~ /^\//) {
        my $absolute_path = abs_path($dir);
        $dir = $absolute_path if $absolute_path;
    }
    return ('git', '-C', $dir);
}

sub _format_git_error ($self, $result, $error_message) {
    my $dir = $self->dir;
    $error_message .= " ($dir): " . $result->{stdout} . $result->{stderr} if $result->{stderr} or $result->{stdout};
    return $error_message;
}

sub set_to_latest_master ($self, $args = undef) {
    $self->_validate_attributes;
    if (my $update_remote = $self->config->{update_remote}) {
        my $res = $self->_run_cmd(['remote', 'update', $update_remote]);
        return $self->_format_git_error($res, 'Unable to fetch from origin master') unless $res->{status};
    }

    if (my $update_branch = $self->config->{update_branch}) {
        if ($self->config->{do_cleanup} eq 'yes') {
            my $res = $self->_run_cmd(['reset', '--hard', 'HEAD']);
            return $self->_format_git_error($res, 'Unable to reset repository to HEAD') unless $res->{status};
        }
        my $res = $self->_run_cmd(['rebase', $update_branch]);
        return $self->_format_git_error($res, 'Unable to reset repository to origin/master') unless $res->{status};
    }

    return undef;
}

sub commit ($self, $args = undef) {
    $self->_validate_attributes;

    my @files;

    # stage changes
    for my $cmd (qw(add rm)) {
        next unless $args->{$cmd};
        push(@files, @{$args->{$cmd}});
        my $res = $self->_run_cmd([$cmd, @{$args->{$cmd}}]);
        return $self->_format_git_error($res, "Unable to $cmd via Git") unless $res->{status};
    }

    # commit changes
    my $message = $args->{message};
    my $author = sprintf('--author=%s <%s>', $self->user->fullname, $self->user->email);
    my $res = $self->_run_cmd(['commit', '-q', '-m', $message, $author, @files]);
    return $self->_format_git_error($res, 'Unable to commit via Git') unless $res->{status};

    # push changes
    if (($self->config->{do_push} || '') eq 'yes') {
        $res = $self->_run_cmd(['push']);
        return $self->_format_git_error($res, 'Unable to push Git commit') unless $res->{status};
    }

    return undef;
}

sub get_current_branch ($self) {
    my $r = $self->_run_cmd(['branch', '--show-current']);
    die $self->_format_git_error($r, 'Error detecting current branch') unless $r->{status};
    return trim($r->{stdout});
}

sub check_sha ($self, $sha) {
    my $r = $self->_run_cmd(['rev-parse', '--verify', '-q', $sha]);
    return 1 if $r->{return_code} == 0;
    return 0 if $r->{return_code} == 128;
    die $self->_format_git_error($r, "Internal Git error: Unexpected exit code $r->{return_code}") unless $r->{status};
}

sub get_remote_default_branch ($self, $url) {
    my $r = $self->_run_cmd(['ls-remote', '--symref', $url, 'HEAD'], {include_git_path => 0, ssh_batchmode => 1});
    die qq/Error detecting remote default branch name for "$url": $r->{stdout} $r->{stderr}/
      unless $r->{status} && $r->{stdout} =~ m{refs/heads/(\S+)\s+HEAD};
    return $1;
}

sub clone_url ($self, $url) {
    my $r = $self->_run_cmd(['clone', $url, $self->dir], {include_git_path => 0, ssh_batchmode => 1});
    die $self->_format_git_error($r, qq/Failed to clone "$url"/) unless $r->{status};
}

sub get_origin_url ($self) {
    my $r = $self->_run_cmd(['remote', 'get-url', 'origin']);
    die $self->_format_git_error($r, 'Failed to get origin url') unless $r->{status};
    return trim($r->{stdout});
}

sub fetch ($self, $branch_arg) {
    my $r = $self->_run_cmd(['fetch', 'origin', $branch_arg], {ssh_batchmode => 1});
    die $self->_format_git_error($r, "Failed to fetch from '$branch_arg'") unless $r->{status};
}

sub reset_hard ($self, $branch) {
    my $r = $self->_run_cmd(['reset', '--hard', "origin/$branch"]);
    die $self->_format_git_error($r, "Failed to reset to 'origin/$branch'") unless $r->{status};
}

sub is_workdir_clean ($self) {
    my $r = $self->_run_cmd(['diff-index', 'HEAD', '--exit-code']);
    die $self->_format_git_error($r, 'Internal Git error: Unexpected exit code ' . $r->{return_code})
      if $r->{return_code} > 1;
    return $r->{status};
}

1;
