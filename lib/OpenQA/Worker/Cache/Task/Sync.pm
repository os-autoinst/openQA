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

package OpenQA::Worker::Cache::Task::Sync;

use Mojo::Base 'Mojolicious::Plugin';
use Mojo::URL;
use constant LOCK_RETRY_DELAY   => 30;
use constant MINION_LOCK_EXPIRE => 99999;    # ~27 hours

use OpenQA::Worker::Cache::Client;
use OpenQA::Worker::Cache;

# TODO: extract common function/attributes from tasks.
has client => sub { OpenQA::Worker::Cache::Client->new };

sub _dequeue { shift->client->_dequeue_job(pop) }
sub _gen_guard_name { join('.', shift->client->session_token, pop) }

sub register {
    my ($self, $app) = @_;

    $app->minion->add_task(
        cache_tests => sub {
            my ($job, $from, $to) = @_;
            my $_guard = join('.', $from, $to);
            my $guard_name = $self->_gen_guard_name($_guard);

            return $job->remove unless defined $from && defined $to;
            return $job->retry({delay => LOCK_RETRY_DELAY})
              unless my $guard = $app->minion->guard($guard_name, MINION_LOCK_EXPIRE);
            $app->log->debug("[$$] [Job #" . $job->id . "] Guard: $guard_name Sync: $from to $to");
            $app->log->debug("[$$] Job dequeued ") if $self->_dequeue($_guard);
            $OpenQA::Utils::app = undef;
            {
                my $output;
                open my $handle, '>', \$output;
                local *STDERR = $handle;
                local *STDOUT = $handle;

                my @cmd = (qw(rsync -avHP), "$from/", qw(--delete), "$to/tests/");
                $app->log->debug("[$$] [Job #" . $job->id . "] Calling " . join(' ', @cmd));
                system(@cmd);
                $job->finish($? >> 8);
                $job->note(output => $output);
                print $output;
            }
            $app->log->debug("[$$] [Job #" . $job->id . "] Finished");
        });
}

=encoding utf-8

=head1 NAME

OpenQA::Worker::Cache::Task::Sync - Cache Service task Sync

=head1 SYNOPSIS

    use Mojolicious::Lite;
    use Mojolicious::Plugin::Minion::Admin;
    use OpenQA::Worker::Cache::Task::Sync;

    plugin Minion => { SQLite => ':memory:' };
    plugin 'OpenQA::Worker::Cache::Task::Sync';

=head1 DESCRIPTION

OpenQA::Worker::Cache::Task::Sync is the task that minions of the OpenQA Cache Service
are executing to handle the tests and needles syncing.

=head1 METHODS

OpenQA::Worker::Cache::Task::Sync inherits all methods from L<Mojolicious::Plugin>
and implements the following new ones:

=head2 register()

Registers the task inside L<Minion>.

=cut

1;
