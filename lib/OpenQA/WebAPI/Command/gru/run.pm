# Copyright (C) 2018 SUSE LLC
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

package OpenQA::WebAPI::Command::gru::run;
use Mojo::Base 'Minion::Command::minion::worker';

use Mojo::Util 'getopt';
use OpenQA::WebAPI::GruJob;

has description => 'Start Gru worker';
has usage       => sub { shift->extract_usage };

sub run {
    my ($self, @args) = @_;

    getopt \@args, 'o|oneshot' => \(my $oneshot);

    my $minion = $self->app->minion;
    $minion->on(
        worker => sub {
            my ($minion, $worker) = @_;
            $worker->on(
                dequeue => sub {
                    my ($worker, $job) = @_;

                    # Reblessing the job is fine for now, but in the future it would be nice
                    # to use a role instead
                    bless $job, 'OpenQA::WebAPI::GruJob';
                });
        });

    if   ($oneshot) { $minion->perform_jobs }
    else            { $self->SUPER::run(@args) }
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
    -o, --oneshot   Perform all currently enqueued jobs and then exit

    See 'script/openqa minion worker -h' for all available options.


=head1 DESCRIPTION

L<OpenQA::WebAPI::Command::gru::run> is a subclass of
L<Minion::Command::minion::worker> that adds Gru features with
L<OpenQA::WebAPI::GruJob>.

=cut
