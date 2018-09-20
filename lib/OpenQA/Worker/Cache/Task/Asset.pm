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

use Mojo::Base 'Mojolicious::Plugin';
use constant LOCK_RETRY_DELAY   => 30;
use constant MINION_LOCK_EXPIRE => 999999999;

use OpenQA::Worker::Cache;
use OpenQA::Worker::Common;    # FIXME: This import needs to disappear.
has ua => sub { Mojo::UserAgent->new };
has cache => sub {
    my ($worker_settings, undef) = OpenQA::Worker::Common::read_worker_config(undef, undef);
    OpenQA::Worker::Cache->new(
        host     => 'localhost',
        location => ($ENV{CACHE_DIR} || $worker_settings->{CACHEDIRECTORY}));
};

sub token {
    shift->ua->get('http://localhost:3000/session_token')->result->json->{session_token};
}

sub dequeue {
    !!(
        shift->ua->get('http://localhost:3000/dequeue/' . shift)->result->json->{status} eq
        OpenQA::Worker::Cache::ASSET_STATUS_PROCESSED);
}

sub _gen_guard_name { join('.', shift->token, pop) }

sub register {
    my ($self, $app) = @_;
    $app->plugin(Minion => {SQLite => 'sqlite:' . $self->cache->db_file});

    # Make it a helper
    $app->helper(asset_task => sub { $self });

    $app->minion->add_task(
        cache_asset => sub {
            my ($job, $id, $type, $asset_name, $host) = @_;
            my $guard_name = $self->_gen_guard_name($asset_name);
            return $job->remove unless defined $asset_name && defined $type && defined $host;

            return $job->retry({delay => LOCK_RETRY_DELAY})
              unless my $guard = $app->minion->guard($guard_name, MINION_LOCK_EXPIRE);
            $app->log->debug("[$$] [Job #" . $job->id . "] Guard: $guard_name Download: $asset_name");

            $app->log->debug("[$$] Job dequeued ") if $self->dequeue($asset_name);

            # Do the real download
            $self->cache->host($host);
            $self->cache->get_asset({id => $id}, $type, $asset_name);
            $app->log->debug("[$$] [Job #" . $job->id . "] Finished");
        });
}

1;
