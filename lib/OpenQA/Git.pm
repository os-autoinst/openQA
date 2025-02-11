# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Git;

use Mojo::Base -base, -signatures;
use Mojo::Util 'trim';
use Cwd 'abs_path';
use Mojo::File 'path';
use OpenQA::Utils qw(run_cmd_with_log_return_error);

has 'app';
has 'dir';
has 'user';

my %CHECK_OPTIONS = (expected_return_codes => {0 => 1, 1 => 1});

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
    my $batchmode = $options->{batchmode} // 0;
    my @cmd;
    push @cmd, 'env', 'GIT_SSH_COMMAND=ssh -oBatchMode=yes', 'GIT_ASKPASS=', 'GIT_TERMINAL_PROMPT=false' if $batchmode;
    push @cmd, $self->_prepare_git_command($include_git_path), @$args;

    my $result = run_cmd_with_log_return_error(\@cmd, expected_return_codes => $options->{expected_return_codes});
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
        $res = $self->_run_cmd(['push'], {batchmode => 1});
        return undef if $res->{status};

        my $msg = 'Unable to push Git commit';
        if ($res->{return_code} == 128 and $res->{stderr} =~ m/Authentication failed for .http/) {
            $msg .= '. See https://open.qa/docs/#_setting_up_git_support on how to setup git support and possibly push via ssh.';
        }
        return $self->_format_git_error($res, $msg);
    }

    return undef;
}

sub get_current_branch ($self) {
    my $r = $self->_run_cmd(['branch', '--show-current']);
    die $self->_format_git_error($r, 'Error detecting current branch') unless $r->{status};
    return trim($r->{stdout});
}

sub invoke_command ($self, $command_and_args) {
    my $r = $self->_run_cmd($command_and_args);
    $r->{status} or die $self->_format_git_error($r, "Failed to invoke Git command $command_and_args->[0]");
}

sub check_sha ($self, $sha) {
    my $r = $self->_run_cmd(['rev-parse', '--verify', '-q', $sha], \%CHECK_OPTIONS);
    return 0 if $r->{return_code} == 1;
    if ($r->{return_code} == 0) {
        # rev-parse returns a sha, $sha could be a branchname. if $sha matches
        # the beginning of the returned sha, we're good
        return 1 if $r->{stdout} =~ m/^\Q$sha/;
        return 0;
    }
    die $self->_format_git_error($r, "Internal Git error: Unexpected exit code $r->{return_code}") unless $r->{status};
}

sub get_remote_default_branch ($self, $url) {
    my $r = $self->_run_cmd(['ls-remote', '--symref', $url, 'HEAD'], {include_git_path => 0, batchmode => 1});
    die qq/Error detecting remote default branch name for "$url": $r->{stdout} $r->{stderr}/
      unless $r->{status} && $r->{stdout} =~ m{refs/heads/(\S+)\s+HEAD};
    return $1;
}

sub clone_url ($self, $url) {
    my $r = $self->_run_cmd(['clone', $url, $self->dir], {include_git_path => 0, batchmode => 1});
    die $self->_format_git_error($r, qq/Failed to clone "$url"/) unless $r->{status};
}

sub get_origin_url ($self) {
    my $r = $self->_run_cmd(['remote', 'get-url', 'origin']);
    die $self->_format_git_error($r, 'Failed to get origin url') unless $r->{status};
    return trim($r->{stdout});
}

sub fetch ($self, $branch_arg) {
    my $r = $self->_run_cmd(['fetch', 'origin', $branch_arg], {batchmode => 1});
    die $self->_format_git_error($r, "Failed to fetch from '$branch_arg'") unless $r->{status};
}

sub reset_hard ($self, $branch) {
    my $r = $self->_run_cmd(['reset', '--hard', "origin/$branch"]);
    die $self->_format_git_error($r, "Failed to reset to 'origin/$branch'") unless $r->{status};
}

sub is_workdir_clean ($self) {
    my $r = $self->_run_cmd(['diff-index', 'HEAD', '--exit-code'], \%CHECK_OPTIONS);
    die $self->_format_git_error($r, 'Internal Git error: Unexpected exit code ' . $r->{return_code})
      if $r->{return_code} > 1;
    return $r->{status};
}

sub cache_ref ($self, $ref, $relative_path, $output_file) {
    if (-f $output_file) {
        eval { path($output_file)->touch };
        return $@ ? $@ : undef;
    }
    my @git = $self->_prepare_git_command(1);
    my $res = run_cmd_with_log_return_error [@git, 'show', "$ref:./$relative_path"], output_file => $output_file;
    return undef if $res->{status};
    unlink $output_file;
    return $self->_format_git_error($res, 'Unable to cache Git ref');
}

1;
