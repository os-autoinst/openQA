# Copyright 2018-2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CacheService::Task::Asset;
use Mojo::Base 'Mojolicious::Plugin';

sub register {
    my ($self, $app) = @_;

    $app->minion->add_task(cache_asset => \&_cache_asset);
}

sub _cache_asset {
    my ($job, $id, $type, $asset_name, $host) = @_;

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
    my $ctx = $log->context("[#$job_id]");
    $ctx->info(qq{Downloading: "$asset_name"});

    # Log messages need to be logged by this service as well as captured and
    # forwarded to the worker (for logging on both sides)
    my $output = '';
    $log->on(
        message => sub {
            my ($log, $level, @lines) = @_;
            $output .= "[$level] " . join "\n", @lines, '';
        });

    my $cache = $app->cache->log($ctx)->refresh;
    $cache->get_asset($host, {id => $id}, $type, $asset_name);
    $job->note(output => $output);
    $ctx->info('Finished download');
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
