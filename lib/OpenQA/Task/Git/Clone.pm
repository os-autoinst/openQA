# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::Git::Clone;
use Mojo::Base 'Mojolicious::Plugin', -signatures;
use Mojo::Util 'trim';

use OpenQA::Utils qw(run_cmd_with_log_return_error);
use Mojo::File;
use Time::Seconds 'ONE_HOUR';

sub register ($self, $app, @) {
    $app->minion->add_task(git_clone => \&_git_clone_all);
}


# $clones is a hashref with paths as keys and urls to git repos as values.
# The urls may also refer to a branch via the url fragment.
# If no branch is set, the default branch of the remote (if target path doesn't exist yet)
# or local checkout is used.
# If the target path already exists, an update of the specified branch is performed,
# if the url matches the origin remote.

sub _git_clone_all ($job, $clones) {
    my $app = $job->app;
    my $job_id = $job->id;

    # Prevent multiple git clone tasks for the same path to run in parallel
    my @guards;
    my $retry_delay = {delay => 30 + int(rand(10))};
    for my $path (sort keys %$clones) {
        $path = Mojo::File->new($path)->realpath if (-e $path);    # resolve symlinks
        my $guard = $app->minion->guard("git_clone_${path}_task", 2 * ONE_HOUR);
        return $job->retry($retry_delay) unless $guard;
        push(@guards, $guard);
    }

    my $log = $app->log;
    my $ctx = $log->context("[#$job_id]");

    # iterate clones sorted by path length to ensure that a needle dir is always cloned after the corresponding casedir
    for my $path (sort { length($a) <=> length($b) } keys %$clones) {
        my $url = $clones->{$path};
        die "Don't even think about putting '..' into '$path'." if $path =~ /\.\./;
        eval { _git_clone($job, $ctx, $path, $url) };
        next unless my $error = $@;
        my $max_retries = $ENV{OPENQA_GIT_CLONE_RETRIES} // 10;
        return $job->retry($retry_delay) if $job->retries < $max_retries;
        return $job->fail($error);
    }
}

sub _get_current_branch ($path) {
    my $r = run_cmd_with_log_return_error(['git', '-C', $path, 'branch', '--show-current']);
    die "Error detecting current branch for '$path': $r->{stderr}" unless $r->{status};
    return trim($r->{stdout});
}

sub _ssh_git_cmd($git_args) {
    return ['env', 'GIT_SSH_COMMAND="ssh -oBatchMode=yes"', 'git', @$git_args];
}

sub _get_remote_default_branch ($url) {
    my $r = run_cmd_with_log_return_error(_ssh_git_cmd(['ls-remote', '--symref', $url, 'HEAD']));
    die "Error detecting remote default branch name for '$url': $r->{stderr}"
      unless $r->{status} && $r->{stdout} =~ /refs\/heads\/(\S+)\s+HEAD/;
    return $1;
}

sub _git_clone_url_to_path ($url, $path) {
    my $r = run_cmd_with_log_return_error(_ssh_git_cmd(['clone', $url, $path]));
    die "Failed to clone $url into '$path': $r->{stderr}" unless $r->{status};
}

sub _git_get_origin_url ($path) {
    my $r = run_cmd_with_log_return_error(['git', '-C', $path, 'remote', 'get-url', 'origin']);
    die "Failed to get origin url for '$path': $r->{stderr}" unless $r->{status};
    return trim($r->{stdout});
}

sub _git_fetch ($path, $branch_arg) {
    my $r = run_cmd_with_log_return_error(_ssh_git_cmd(['-C', $path, 'fetch', 'origin', $branch_arg]));
    die "Failed to fetch from '$branch_arg': $r->{stderr}" unless $r->{status};
}

sub _git_gc ($path) {
    my $r = run_cmd_with_log_return_error(_ssh_git_cmd(['-C', $path, 'gc', '--auto', '--quiet']));
    die "Failed to gc '$path': $r->{stderr}" unless $r->{status};
}

sub _git_diff_index ($path) {
    my $r = run_cmd_with_log_return_error(_ssh_git_cmd(['-C', $path, 'diff-index', 'HEAD', '--exit-code']));
    unless ($r->{status}) {
        # dirty git status
        return "diff-index: $r->{stdout}" if $r->{return_code} >> 8 == 1;
        die "Failed to diff-index '$path': $r->{stderr}";
    }
    return 0;
}

sub _git_reset_hard ($path, $branch) {
    my $r = run_cmd_with_log_return_error(['git', '-C', $path, 'reset', '--hard', "origin/$branch"]);
    die "Failed to reset to 'origin/$branch': $r->{stderr}" unless $r->{status};
}

sub _git_clone ($job, $ctx, $path, $url) {
    my $requested_branch = '';
    if ($url) {
        # given a git url, do initial clone
        $ctx->debug(qq{Updating $path to $url});
        $url = Mojo::URL->new($url);
        $requested_branch = $url->fragment;
        $url->fragment(undef);
        my $remote_default_branch = _get_remote_default_branch($url);
        $requested_branch ||= $remote_default_branch;
        $ctx->debug(qq{Remote default branch $remote_default_branch});
        die "Unable to detect remote default branch for '$url'" unless $remote_default_branch;

        if (!-d $path) {
            _git_clone_url_to_path($url, $path);
            # update local branch to latest remote branch version
            _git_fetch($path, "$requested_branch:$requested_branch")
              if ($requested_branch ne $remote_default_branch);
        }

        my $origin_url = _git_get_origin_url($path);
        if ($url ne $origin_url) {
            $ctx->warn("Local checkout at $path has origin $origin_url but requesting to clone from $url");
            return;
        }
    }
    else {
        # look for existing clone in the given path
        my $origin_url = _git_get_origin_url($path);
        $ctx->debug(qq{Updating $path to $origin_url});
        $requested_branch = _get_remote_default_branch($origin_url);
    }
    if (my $is_dirty = _git_diff_index($path)) {
        $ctx->warn("Clone at '$path' has dirty status, not updating: $is_dirty");
        return;
    }

    _git_gc($path);
    my $current_branch = _get_current_branch($path);
    # TODO deal with conflicts because of save_needle
    # see fetchneedles
    if ($requested_branch eq $current_branch) {
        # updating default branch (including checkout)
        _git_fetch($path, $requested_branch);
        _git_reset_hard($path, $requested_branch);
    }
    else {
        # updating local branch to latest remote branch version
        _git_fetch($path, "$requested_branch:$requested_branch");
    }
}

1;
