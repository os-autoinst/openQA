# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::Needle::LimitTempRefs;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use File::Find;
use File::stat;
use Fcntl qw(S_ISDIR);
use OpenQA::Needles;
use OpenQA::Task::SignalGuard;
use Time::Seconds;

my $retention;

sub register ($self, $app, $job) {
    $retention = $app->config->{'scm git'}->{temp_needle_refs_retention} * ONE_MINUTE;
    $app->minion->add_task(limit_temp_needle_refs => sub ($job) { _limit($app, $job) });
}

sub _limit ($app, $job) {
    my $ensure_task_retry_on_termination_signal_guard = OpenQA::Task::SignalGuard->new($job);

    return $job->finish({error => 'Another job to remove needle versions is running. Try again later.'})
      unless my $guard = $app->minion->guard('limit_needle_versions_task', 2 * ONE_HOUR);

    # remove all temporary needles which haven't been accessed in time period specified in config
    my $temp_dir = OpenQA::Needles::temp_dir;
    return undef unless -d $temp_dir;
    my $now = time;
    my $wanted = sub {
        return undef unless my $lstat = lstat $File::Find::name;
        return rmdir $File::Find::name if S_ISDIR($lstat->mode);    # remove all empty dirs
        return unlink $File::Find::name if ($now - $lstat->mtime) > $retention;
    };
    find({no_chdir => 1, bydepth => 1, wanted => $wanted}, $temp_dir);
}

1;
