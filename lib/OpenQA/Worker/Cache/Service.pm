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

package OpenQA::Worker::Cache::Service;

use Mojolicious::Lite;
use OpenQA::Worker::Cache::Task::Asset;
use Mojolicious::Plugin::Minion;
use OpenQA::Worker::Cache;
use Mojo::Collection;
use Mojolicious::Plugin::Minion::Admin;

BEGIN { srand(time) }

my $_token;

sub _gen_session_token { $_token = int(rand(999999999999)) }

my $enqueued = Mojo::Collection->new;
app->hook(
    before_server_start => sub {
        _gen_session_token();
        $enqueued = Mojo::Collection->new;
    });

plugin Minion => {SQLite => 'sqlite:' . OpenQA::Worker::Cache->from_worker->db_file};
plugin 'Minion::Admin';
plugin 'OpenQA::Worker::Cache::Task::Asset';
plugin 'OpenQA::Worker::Cache::Task::Sync';

sub SESSION_TOKEN { $_token }

sub _gen_guard_name { join('.', SESSION_TOKEN, pop) }

sub _exists { !!(defined $_[0] && exists $_[0]->{total} && $_[0]->{total} > 0) }

sub active { !app->minion->lock(shift, 0) }

sub get_job_by_token {
    eval {
        { app->minion->backend->list_jobs(0, 1, {note => {token => shift}})->{jobs}[0] }
    }
}

sub enqueued {
    my $lock = shift;
    !!($enqueued->grep(sub { $_ eq $lock })->size == 1);
}

sub dequeue {
    my $lock = shift;
    $enqueued = $enqueued->grep(sub { $_ ne $lock });
}

sub enqueue {
    push @$enqueued, shift;
}

sub run {
    shift;
    require OpenQA::Utils;
    OpenQA::Utils::set_listen_address(7844);
    $ENV{MOJO_INACTIVITY_TIMEOUT} = 300;
    require Mojolicious::Commands;
    Mojolicious::Commands->start_app('OpenQA::Worker::Cache::Service', @_);
}

get '/session_token' => sub { shift->render(json => {session_token => SESSION_TOKEN()}) };

get '/info' => sub { $_[0]->render(json => shift->minion->stats) };

post '/download' => sub {
    my $c = shift;

    my $data  = $c->req->json;
    my $id    = $data->{id};
    my $type  = $data->{type};
    my $asset = $data->{asset};
    my $host  = $data->{host};
    # Specific error cases for missing fields
    return $c->render(json => {status => OpenQA::Worker::Cache::ASSET_STATUS_ERROR, error => 'No ID defined'})
      unless defined $id;
    return $c->render(json => {status => OpenQA::Worker::Cache::ASSET_STATUS_ERROR, error => 'No Asset defined'})
      unless defined $asset;
    return $c->render(json => {status => OpenQA::Worker::Cache::ASSET_STATUS_ERROR, error => 'No Asset type defined'})
      unless defined $type;
    return $c->render(json => {status => OpenQA::Worker::Cache::ASSET_STATUS_ERROR, error => 'No Host defined'})
      unless defined $host;
    app->log->debug("Requested: ID: $id Type: $type Asset: $asset Host: $host ");

    my $lock = _gen_guard_name($asset);

    return $c->render(json => {status => OpenQA::Worker::Cache::ASSET_STATUS_DOWNLOADING}) if active($lock);
    return $c->render(json => {status => OpenQA::Worker::Cache::ASSET_STATUS_IGNORE})      if enqueued($lock);

    $c->minion->enqueue(cache_asset => [$id, $type, $asset, $host]);
    enqueue($lock);

    $c->render(json => {status => OpenQA::Worker::Cache::ASSET_STATUS_ENQUEUED});
};

post '/status' => sub {
    my $c    = shift;
    my $data = $c->req->json;
    my $lock = _gen_guard_name($data->{lock});
    my $j    = get_job_by_token($lock);

    $c->render(
        json => {
            status => (
                  active($lock)   ? OpenQA::Worker::Cache::ASSET_STATUS_DOWNLOADING
                : enqueued($lock) ? OpenQA::Worker::Cache::ASSET_STATUS_IGNORE
                :                   OpenQA::Worker::Cache::ASSET_STATUS_PROCESSED
            ),
            (result => $j->{result}, output => $j->{notes}->{output}) x !!($j)});
};

# NOTE: Bit more generic - Specfic assets routes calls for refactoring wrt this implementation
post '/execute_task' => sub {
    my $c    = shift;
    my $data = $c->req->json;
    my $lock = _gen_guard_name($data->{lock});
    my $task = $data->{task};
    my $args = $data->{args};

    return $c->render(json => {status => OpenQA::Worker::Cache::ASSET_STATUS_ERROR, error => 'No Task defined'})
      unless defined $task;
    return $c->render(json => {status => OpenQA::Worker::Cache::ASSET_STATUS_ERROR, error => 'No Arguments defined'})
      unless defined $args;

    $c->minion->enqueue($task => $args);
    enqueue($lock);

    $c->render(json => {status => OpenQA::Worker::Cache::ASSET_STATUS_ENQUEUED});
};

post '/dequeue' => sub {
    my $c    = shift;
    my $data = $c->req->json;
    my $lock = _gen_guard_name($data->{lock});

    dequeue($lock);
    $c->render(json => {status => OpenQA::Worker::Cache::ASSET_STATUS_PROCESSED});
};

app->minion->backend->reset;

=encoding utf-8

=head1 NAME

OpenQA::Worker::Cache::Service - OpenQA Cache Service

=head1 SYNOPSIS

    use OpenQA::Worker::Cache::Service;

    # Start the daemon
    OpenQA::Worker::Cache::Service->run(qw(daemon));

    # Start one or more Minions with:
    OpenQA::Worker::Cache::Service->run(qw(minion worker))

=head1 DESCRIPTION

OpenQA::Worker::Cache::Service is the OpenQA Cache Service, which is meant to be run
standalone.

=head1 GET ROUTES

OpenQA::Worker::Cache::Service is a L<Mojolicious::Lite> application, and it is exposing the following GET routes.

=head2 /minion

Redirects to the L<Mojolicious::Plugin::Minion::Admin> Dashboard.

=head2 /info

Returns Minon statistics, see L<https://metacpan.org/pod/Minion#stats>.

=head2 /session_token

Returns the current session token.

=head1 POST ROUTES

OpenQA::Worker::Cache::Service is exposing the following POST routes.

=head2 /download

Enqueue the asset download. It acceps a POST JSON payload of the form:

      { id => 9999, type => 'hdd', asset=> 'default.qcow2', host=> 'openqa.opensuse.org' }

=head2 /status

Retrieve download asset status. It acceps a POST JSON payload of the form:

      { asset=> 'default.qcow2' }

=head2 /dequeue

Dequeues a job from the queue of jobs which are still inactive. It acceps a POST JSON payload of the form:

      { asset=> 'default.qcow2' }

=cut

!!42;
