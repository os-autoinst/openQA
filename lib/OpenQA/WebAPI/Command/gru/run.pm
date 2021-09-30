# Copyright 2018-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Command::gru::run;
use Mojo::Base 'Minion::Command::minion::worker';

use Mojo::Util 'getopt';

has description => 'Start Gru worker';
has usage => sub { shift->extract_usage };

sub run {
    my ($self, @args) = @_;

    getopt \@args, ['pass_through'], 'o|oneshot' => \my $oneshot, 'reset-locks' => \my $reset_locks;

    my $minion = $self->app->minion;
    return $minion->perform_jobs if $oneshot;

    if ($reset_locks) {
        $self->app->log->info('Resetting all leftover Gru locks after restart');
        $minion->reset({locks => 1});
    }
    $self->SUPER::run(@args);
}

1;

=encoding utf8

=head1 NAME

OpenQA::WebAPI::Command::gru::run - Gru run command

=head1 SYNOPSIS

  Usage: APPLICATION gru run [OPTIONS]

    script/openqa gru run
    script/openqa gru run -o

  Options:
    -o, --oneshot       Perform all currently enqueued jobs and then exit
        --reset-locks   Reset all remaining locks before startup

    See 'script/openqa minion worker -h' for all available options.


=head1 DESCRIPTION

L<OpenQA::WebAPI::Command::gru::run> is a subclass of
L<Minion::Command::minion::worker> that adds Gru features with
L<OpenQA::Shared::GruJob>.

=cut
