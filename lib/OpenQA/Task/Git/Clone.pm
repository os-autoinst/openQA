# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::Git::Clone;
use Mojo::Base 'Mojolicious::Plugin', -signatures;
use Mojo::Util 'trim';

use Mojo::File;
use Feature::Compat::Try;
use List::Util qw(min);
use OpenQA::Log qw(log_debug);
use OpenQA::Git::ServerAvailability qw(report_server_unavailable report_server_available SKIP FAIL);
use Time::Seconds qw(ONE_HOUR);

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
    # failsafe check - we should never actually get here with git
    # disabled, but just in case
    return if (($app->config->{global}->{scm} // '') ne 'git');

    my $retry_delay = {delay => 30 + int(rand(10))};
    # Prevent multiple git_clone tasks for the same path to run in parallel
    my @guards;
    my $is_path_only = 1;
    for my $path (sort keys %$clones) {
        $path = Mojo::File->new($path)->realpath if -e $path;    # resolve symlinks
        $is_path_only &&= !(defined $clones->{$path});
        my $guard_name = "git_clone_${path}_task";
        my $guard = $app->minion->guard($guard_name, 2 * ONE_HOUR);
        unless ($guard) {
            log_debug("Could not get guard for $guard_name, retrying in $retry_delay->{delay}s");
            return $job->retry($retry_delay);
        }
        push @guards, $guard;
    }

    my $log = $app->log;
    my $ctx = $log->context("[#$job_id]");

    # iterate clones sorted by path length to ensure that a needle dir is always cloned after the corresponding casedir
    for my $path (sort { length($a) <=> length($b) || $a cmp $b } keys %$clones) {
        die "Don't even think about putting '..' into '$path'." if $path =~ /\.\./;

        my $git = OpenQA::Git->new(app => $app, dir => $path);
        my $origin_url = -d $path ? $git->get_origin_url : undef;
        my $url = $origin_url // $clones->{$path};
        my $server_host = _extract_server_host($url);
        my $error;
        try {
            _git_clone($git, $ctx, $path, $clones->{$path}, $origin_url);
            report_server_available($app, $server_host);
            next;
        }
        catch ($e) { $error = $e }
        if ($error =~ /Internal API unreachable/) {
            my $outcome = report_server_unavailable($app, $server_host);
            if ($outcome eq 'SKIP') {
                $ctx->info('Git server outage likely, skipping clone job.');
                return;
            }
            elsif ($outcome eq 'FAIL') {
                $ctx->info('Prolonged Git server outage, failing the job.');
                return $job->fail($error);
            }
        }

        # unblock openQA jobs despite network errors under best-effort configuration
        my $retries = $job->retries;
        my $max_retries = $ENV{OPENQA_GIT_CLONE_RETRIES} // 10;
        my $max_best_effort_retries = min($max_retries, $ENV{OPENQA_GIT_CLONE_RETRIES_BEST_EFFORT} // 2);
        my $gru_task_id = $job->info->{notes}->{gru_id};
        if (   $is_path_only
            && defined($gru_task_id)
            && ($error =~ m/disconnect|curl|stream.*closed|/i)
            && $git->config->{git_auto_update_method} eq 'best-effort'
            && $retries >= $max_best_effort_retries)
        {
            $app->schema->resultset('GruDependencies')->search({gru_task_id => $gru_task_id})->delete;
        }

        return $job->retry($retry_delay) if $retries < $max_retries;
        return $job->fail($error);
    }
}

sub _git_clone ($git, $ctx, $path, $url, $origin_url) {
    $ctx->debug(sprintf q{Updating '%s' to '%s'}, $path, ($url // 'n/a'));
    my $requested_branch;
    if ($url) {
        $url = Mojo::URL->new($url);
        $requested_branch = $url->fragment;
        $url->fragment(undef);

        # An initial clone fetches all refs, we are done
        return $git->clone_url($url) unless -d $path;

        if ($url ne $origin_url) {
            $ctx->info(<<~"END_OF_MESSAGE");
                Local checkout at $path has origin $origin_url but requesting to clone from $url. The requested URL will not be cloned.
                END_OF_MESSAGE
            return;
        }
    }
    else {
        $url = $origin_url;
    }

    return if ($requested_branch and $requested_branch !~ tr/a-f0-9//c and $git->check_sha($requested_branch));

    die <<~"END_OF_MESSAGE" unless $git->is_workdir_clean;
        NOT updating dirty Git checkout at '$path'.
        In case this is expected (e.g. on a development openQA instance) you can disable auto-updating.
        Then the Git checkout will no longer be kept up-to-date, though. Checkout http://open.qa/docs/#_getting_tests for details.
        END_OF_MESSAGE

    unless ($requested_branch) {
        my $remote_default = $git->get_remote_default_branch($url);
        $requested_branch = $remote_default;
        $ctx->debug(qq{Remote default branch $remote_default});
    }

    my $current_branch = $git->get_current_branch;
    # updating default branch (including checkout)
    $git->fetch($requested_branch);
    $git->reset_hard($requested_branch) if ($requested_branch eq $current_branch);
}

sub _extract_server_host ($url) {
    if ($url =~ m{^[^@]+@([^:]+):}) {
        # e.g. "git@gitlab.suse.de:qa/foo", "user@host:repo"
        return $1;
    }
    else {
        my $mojo_url = Mojo::URL->new($url);
        return $mojo_url->host // 'other';
    }
}

1;
