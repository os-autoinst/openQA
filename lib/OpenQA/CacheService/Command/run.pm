# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CacheService::Command::run;
use Mojo::Base 'Minion::Command::minion::worker', -signatures;

use Mojo::Util 'getopt';

has description => 'Start Minion worker';
has usage => sub ($self) { $self->extract_usage };

sub reset_leftovers ($self) {
    my $app = $self->app;
    $app->log->info('Resetting all leftover locks after restart');
    $app->minion->reset({locks => 1});

    # Retry active jobs left from previous workers that were killed or went away
    my $active_jobs = $app->minion->jobs({states => ['active']});
    while (my $info = $active_jobs->next) {
        if (my $job = $app->minion->job($info->{id})) {
            $app->log->info("Retrying leftover active job #$info->{id} after restart");
            $job->retry({delay => 0});
        }
    }

    # Reset any delayed jobs so the new worker picks them up immediately
    my $inactive_jobs = $app->minion->jobs({states => ['inactive']});
    while (my $info = $inactive_jobs->next) {
        if ($info->{delayed} && $info->{delayed} > $info->{time} && (my $job = $app->minion->job($info->{id}))) {
            $app->log->info("Resetting delay for job #$info->{id} after restart");
            $job->retry({delay => 0});
        }
    }

    # Unregister dead workers from before restart
    my $workers = $app->minion->workers;
    while (my $info = $workers->next) {
        $app->log->info("Removing leftover worker #$info->{id} after restart");
        $app->minion->backend->unregister_worker($info->{id});
    }
}

sub run ($self, @args) {
    getopt \@args, ['pass_through'], 'reset-locks' => \my $reset_locks;

    $self->reset_leftovers if $reset_locks;

    # Reset download count after restart (might not be 0 after an unclean exit)
    $self->app->cache->reset_download_count;

    $self->SUPER::run(@args);
}

1;

=encoding utf8

=head1 NAME

OpenQA::CacheService::Command::run - Cache service run command

=head1 SYNOPSIS

  Usage: APPLICATION run [OPTIONS]

    script/openqa-workercache run

  Options:
    --reset-locks   Reset all remaining locks before startup

    See 'script/openqa-workercache minion worker -h' for all available options.


=head1 DESCRIPTION

L<OpenQA::CacheService::Command::run> is a subclass of
L<Minion::Command::minion::worker> that adds cache service features.

=cut
