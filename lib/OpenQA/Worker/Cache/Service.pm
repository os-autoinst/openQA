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

BEGIN { srand(time) }

my $tk;
app->hook(
    before_server_start => sub {
        $tk = int(rand(999999999999));
    });

sub SESSION_TOKEN { $tk }
plugin 'OpenQA::Worker::Cache::Task::Asset';

get '/session_token' => sub { shift->render(json => {session_token => SESSION_TOKEN()}) };
get '/info' => sub { $_[0]->render(json => shift->minion->stats) };

sub _gen_guard_name { join('.', SESSION_TOKEN, pop) }

sub _exists { !!(defined $_[0] && exists $_[0]->{total} && $_[0]->{total} > 0) }

sub enqueued { _exists(app->minion->backend->list_jobs(0, 1, {states => ['inactive'], notes => {token => shift}})) }

sub active { _exists(app->minion->backend->list_jobs(0, 1, {states => ['active'], notes => {token => shift}})) }

post '/download' => sub {
    my $c = shift;

    my $data = $c->req->json;

    my $id    = $data->{'id'};
    my $type  = $data->{'type'};
    my $asset = $data->{'asset'};
    my $host  = $data->{'host'};
    # Specific error cases for missing fields
    return $c->render(json => {status => OpenQA::Worker::Cache::ASSET_STATUS_ERROR, error => "No ID defined"})
      unless defined $id;
    return $c->render(json => {status => OpenQA::Worker::Cache::ASSET_STATUS_ERROR, error => "No Asset defined"})
      unless defined $asset;
    return $c->render(json => {status => OpenQA::Worker::Cache::ASSET_STATUS_ERROR, error => "No Asset  type defined"})
      unless defined $type;
    return $c->render(json => {status => OpenQA::Worker::Cache::ASSET_STATUS_ERROR, error => "No Host defined"})
      unless defined $host;
    app->log->debug("Requested: ID: $id Type: $type Asset: $asset Host: $host ");

    my $lock = _gen_guard_name($asset);

    return $c->render(json => {status => OpenQA::Worker::Cache::ASSET_STATUS_DOWNLOADING}) if active($lock);
    return $c->render(json => {status => OpenQA::Worker::Cache::ASSET_STATUS_IGNORE})      if enqueued($lock);

    $c->minion->enqueue(cache_asset => [$id, $type, $asset, $host] => {notes => {token => $lock}});
    $c->render(json => {status => OpenQA::Worker::Cache::ASSET_STATUS_ENQUEUED});
};

get '/status/#asset' => sub {
    my $c     = shift;
    my $asset = $c->param('asset');
    my $lock  = _gen_guard_name($asset);

    return $c->render(json => {status => OpenQA::Worker::Cache::ASSET_STATUS_DOWNLOADING}) if active($lock);
    return $c->render(json => {status => OpenQA::Worker::Cache::ASSET_STATUS_IGNORE})      if enqueued($lock);
    $c->render(json => {status => OpenQA::Worker::Cache::ASSET_STATUS_PROCESSED});
};

# Start the Mojolicious command system
app->start;

!!42;
