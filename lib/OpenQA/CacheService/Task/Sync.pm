# Copyright 2018-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CacheService::Task::Sync;
use Mojo::Base 'Mojolicious::Plugin';

use Mojo::URL;
use Time::Seconds;

use constant RSYNC_TIMEOUT => $ENV{OPENQA_RSYNC_TIMEOUT} // (30 * ONE_MINUTE);

sub register {
    my ($self, $app) = @_;

    $app->minion->add_task(cache_tests => \&_cache_tests);
}

sub _cache_tests {
    my ($job, $from, $to) = @_;

    my $app = $job->app;
    my $job_id = $job->id;
    my $lock = $job->info->{notes}{lock};
    return $job->finish unless defined $from && defined $to && defined $lock;

    # Handle concurrent requests gracefully and try to share logs
    my $guard = $app->progress->guard($lock, $job_id);
    unless ($guard) {
        my $id = $app->progress->downloading_job($lock);
        $job->note(downloading_job => $id);
        $id ||= 'unknown';
        $job->note(output => qq{Sync "$from" to "$to" was performed by #$id, details are therefore unavailable here});
        return $job->finish;
    }

    my $ctx = $app->log->context("[#$job_id]");
    $ctx->info(qq{Sync: "$from" to "$to"});

    my @cmd = (qw(rsync -avHP --timeout), RSYNC_TIMEOUT, "$from/", qw(--delete), "$to/tests/");
    my $cmd = join ' ', @cmd;
    $ctx->info("Calling: $cmd");
    my $output = `@cmd`;
    my $status = $? >> 8;
    $job->finish("exit code $status");
    $job->note(output => "[info] [#$job_id] Calling: $cmd\n$output");
    $ctx->info("Finished sync: $status");
}

1;

=encoding utf-8

=head1 NAME

OpenQA::CacheService::Task::Sync - Cache Service task Sync

=head1 SYNOPSIS

    plugin 'OpenQA::CacheService::Task::Sync';

=head1 DESCRIPTION

OpenQA::CacheService::Task::Sync is the task that minions of the OpenQA Cache Service
are executing to handle the tests and needles syncing.

=cut
