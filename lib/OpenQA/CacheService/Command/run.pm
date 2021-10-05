# Copyright 2020 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::CacheService::Command::run;
use Mojo::Base 'Minion::Command::minion::worker';

use Mojo::Util 'getopt';

has description => 'Start Minion worker';
has usage       => sub { shift->extract_usage };

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
