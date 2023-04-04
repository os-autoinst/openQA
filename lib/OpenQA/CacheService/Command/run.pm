# Copyright 2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CacheService::Command::run;
use Mojo::Base 'Minion::Command::minion::worker', -signatures;

use Mojo::Util 'getopt';

has description => 'Start Minion worker';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    getopt \@args, ['pass_through'], 'reset-locks' => \my $reset_locks;

    my $app = $self->app;
    if ($reset_locks) {
        $app->log->info('Resetting all leftover locks after restart');
        $app->minion->reset({locks => 1});
    }

    # Reset download count after restart (might not be 0 after an unclean exit)
    $app->cache->reset_download_count;

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
