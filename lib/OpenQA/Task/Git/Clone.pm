# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later
package OpenQA::Task::Git::Clone;
use Mojo::Base 'Mojolicious::Plugin', -signatures;
use OpenQA::Git;

use OpenQA::Utils qw(run_cmd_with_log_return_error);
use Mojo::File;
use Time::Seconds 'ONE_HOUR';

sub register ($self, $app, @) {
    $app->minion->add_task(git_clone => \&_git_clone_all);
}

sub _git_clone_all ($job, $clones) {
    my $app = $job->app;
    my $job_id = $job->id;


    # Prevent multiple git clone tasks for the same path to run in parallel
    my @guards;
    my $retry_delay = {delay => 30 + int(rand(10))};
    for my $path (sort keys %$clones) {
        $path = Mojo::File->new($path)->realpath if (-e $path);    # resolve symlinks
        my $guard = $app->minion->guard(  "git_clone_${path}_task", 2 * ONE_HOUR);
        return $job->retry($retry_delay) unless $guard;
        push(@guards, $guard);
    }

    my $log = $app->log;
    my $ctx = $log->context("[#$job_id]");

    # iterate clones sorted by path length to ensure that a needle dir is always cloned after the corresponding casedir
    for my $path (sort { length($a) <=> length($b) } keys %$clones) {
        my $git = OpenQA::Git->new(app => $app);
        my $url = $clones->{$path};
        die "Don't even think about putting '..' into '$path'." if $path =~ /\.\./;
        eval { _git_clone($git, $job, $ctx, $path, $url) };
        next unless my $error = $@;
        my $max_retries = $ENV{OPENQA_GIT_CLONE_RETRIES} // 10;
        return $job->retry($retry_delay) if $job->retries < $max_retries;
        return $job->fail($error);
    }
}

sub _git_clone ($git, $job, $ctx, $path, $url) {
    $ctx->debug(qq{Updating $path to $url});
    $url = Mojo::URL->new($url);
    my $requested_branch = $url->fragment;
    $url->fragment(undef);
    my $remote_default_branch = $git->get_remote_default_branch($url);
    $requested_branch ||= $remote_default_branch;
    $ctx->debug(qq{Remote default branch $remote_default_branch});
    die "Unable to detect remote default branch for '$url'" unless $remote_default_branch;

    if (!-d $path) {
        $git->git_clone_url_to_path($url, $path);
        # update local branch to latest remote branch version
        $git->git_fetch($path, "$requested_branch:$requested_branch")
          if ($requested_branch ne $remote_default_branch);
    }

    my $origin_url = $git->git_get_origin_url($path);
    if ($url ne $origin_url) {
        $ctx->warn("Local checkout at $path has origin $origin_url but requesting to clone from $url");
        return;
    }

    my $current_branch = $git->get_current_branch($path);
    if ($requested_branch eq $current_branch) {
        # updating default branch (including checkout)
        $git->git_fetch($path, $requested_branch);
        $git->git_reset_hard($path, $requested_branch);
    }
    else {
        # updating local branch to latest remote branch version
        $git->git_fetch($path, "$requested_branch:$requested_branch");
    }
}

1;

