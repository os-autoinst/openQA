# Copyright 2019-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CacheService::Plugin::Helpers;
use Mojo::Base 'Mojolicious::Plugin', -signatures;
use Time::Seconds;

sub register {
    my ($self, $app) = @_;
    # To determine download progress and guard against parallel downloads of the same file
    $app->helper('progress.downloading_job' => \&_progress_downloading_job);
    $app->helper('progress.is_downloading' => \&_progress_is_downloading);
    $app->helper('progress.guard' => \&_progress_guard);
}

sub _progress_downloading_job ($c, $lock) { $c->downloads->find($lock) }

sub _progress_is_downloading ($c, $lock) { !$c->minion->lock("cache_$lock", 0) }

sub _progress_guard ($c, $lock, $job_id) {
    my $guard = $c->minion->guard("cache_$lock", ONE_DAY);
    $c->downloads->add($lock, $job_id) if $guard;
    return $guard;
}

1;
