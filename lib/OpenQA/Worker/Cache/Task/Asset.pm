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

package OpenQA::Worker::Cache::Task::Asset;

use Mojo::Base 'OpenQA::Worker::Cache::Task';
use Mojo::URL;
use constant LOCK_RETRY_DELAY   => 30;
use constant MINION_LOCK_EXPIRE => 99999;    # ~27 hours

use OpenQA::Worker::Cache::Client;
use OpenQA::Worker::Cache;
use OpenQA::Worker::Cache::Request;

has cache => sub { OpenQA::Worker::Cache->from_worker };

sub register {
    my ($self, $app) = @_;

    $app->minion->add_task(
        cache_asset => sub {
            my $job = shift;
            my ($id, $type, $asset_name, $host) = @_;
            my $req = OpenQA::Worker::Cache::Request->new->asset(
                id    => $id,
                type  => $type,
                asset => $asset_name,
                host  => $host
            );
            my $guard_name = $self->_gen_guard_name($req->lock);

            return $job->remove unless defined $asset_name && defined $type && defined $host;
            return $job->retry({delay => LOCK_RETRY_DELAY})
              unless my $guard = $app->minion->guard($guard_name, MINION_LOCK_EXPIRE);
            $app->log->debug("[$$] [Job #" . $job->id . "] Guard: $guard_name Download: $asset_name");
            $app->log->debug("[$$] Job dequeued " . $req->lock) if $self->_dequeue($req->lock);
            $OpenQA::Utils::app = undef;
            my $output;
            {
                open my $handle, '>', \$output;
                local *STDERR = $handle;
                local *STDOUT = $handle;
                # Do the real download
                $self->cache->host($host);
                $self->cache->get_asset({id => $id}, $type, $asset_name);
                $job->note(output => $output);
            }
            print $output;
            $app->log->debug("[$$] [Job #" . $job->id . "] Finished");
        });
}

=encoding utf-8

=head1 NAME

OpenQA::Worker::Cache::Task::Asset - Cache Service task

=head1 SYNOPSIS

    use Mojolicious::Lite;
    use Mojolicious::Plugin::Minion::Admin;
    use OpenQA::Worker::Cache::Task::Asset;

    plugin Minion => { SQLite => ':memory:' };
    plugin 'OpenQA::Worker::Cache::Task::Asset';

=head1 DESCRIPTION

OpenQA::Worker::Cache::Task::Asset is the task that minions of the OpenQA Cache Service
are executing to handle the asset download.

=head1 METHODS

OpenQA::Worker::Cache::Task::Asset inherits all methods from L<Mojolicious::Plugin>
and implements the following new ones:

=head2 register()

Registers the task inside L<Minion>.

=cut

1;
