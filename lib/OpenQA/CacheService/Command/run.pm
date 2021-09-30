# Copyright 2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CacheService::Command::run;
use Mojo::Base 'Minion::Command::minion::worker';

use Mojo::Util 'getopt';

has description => 'Start Minion worker';
has usage => sub { shift->extract_usage };

sub run {
    my ($self, @args) = @_;

    getopt \@args, ['pass_through'], 'reset-locks' => \my $reset_locks;

    if ($reset_locks) {
        my $app = $self->app;
        $app->log->info('Resetting all leftover locks after restart');
        $app->minion->reset({locks => 1});
    }
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
