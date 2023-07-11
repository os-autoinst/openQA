# Copyright 2018-2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CacheService::Task::Asset;
use Mojo::Base 'Mojolicious::Plugin', -signatures;
use OpenQA::Task::SignalGuard;
use Mojo::JSON;

sub register ($self, $app, $conf) { $app->minion->add_task(cache_asset => \&_cache_asset) }

sub _cache_asset ($job, $id, $type = undef, $asset_name = undef, $host = undef) {
    my $ensure_task_retry_on_termination_signal_guard = OpenQA::Task::SignalGuard->new($job);
    my $app = $job->app;
    my $job_id = $job->id;
    my $lock = $job->info->{notes}{lock};
    return $job->finish unless defined $asset_name && defined $type && defined $host && defined $lock;

    # Handle concurrent requests gracefully and try to share logs
    my $guard = $app->progress->guard($lock, $job_id);
    unless ($guard) {
        my $id = $app->progress->downloading_job($lock);
        $job->note(downloading_job => $id);
        $id ||= 'unknown';
        $job->note(output => qq{Asset "$asset_name" was downloaded by #$id, details are therefore unavailable here});
        return $job->finish;
    }

    my $log = $app->log;
    $log->info(qq{Downloading: "$asset_name"});

    # Log messages need to be logged by this service as well as captured and
    # forwarded to the worker (for logging on both sides)
    my $output = '';
    $log->on(
        message => sub ($log, $level, @lines) {
            $output .= join("\n", map { "[$level] [#$job_id] $_" } @lines) . "\n";
        });
    my $cache = $app->cache->log($log)->refresh;
    my $error = $cache->get_asset($host, {id => $id}, $type, $asset_name);
    $job->note(output => $output);
    $job->note(has_download_error => $error ? Mojo::JSON->true : Mojo::JSON->false);
    $log->info('Finished download');
}

1;

=encoding utf-8

=head1 NAME

OpenQA::CacheService::Task::Asset - Cache Service task

=head1 SYNOPSIS

    plugin 'OpenQA::CacheService::Task::Asset';

=head1 DESCRIPTION

OpenQA::CacheService::Task::Asset is the task that minions of the OpenQA Cache Service
are executing to handle the asset download.

=cut
