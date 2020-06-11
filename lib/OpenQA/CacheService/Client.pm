# Copyright (C) 2018-2020 SUSE LLC
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

package OpenQA::CacheService::Client;
use Mojo::Base -base;

use OpenQA::Worker::Settings;
use OpenQA::CacheService::Request::Asset;
use OpenQA::CacheService::Request::Sync;
use OpenQA::CacheService::Response::Info;
use OpenQA::CacheService::Response::Status;
use OpenQA::Utils qw(base_host service_port);
use Mojo::URL;
use Mojo::File 'path';

has host      => sub { 'http://127.0.0.1:' . service_port('cache_service') };
has cache_dir => sub { $ENV{OPENQA_CACHE_DIR} || OpenQA::Worker::Settings->new->global_settings->{CACHEDIRECTORY} };
has ua        => sub { Mojo::UserAgent->new(inactivity_timeout => 300) };

sub info {
    my $self = shift;

    my $tx   = $self->ua->get($self->url('info'));
    my $err  = $self->_error('info', $tx);
    my $data = $tx->res->json // {};

    return OpenQA::CacheService::Response::Info->new(data => $data, error => $err);
}

sub status {
    my ($self, $request) = @_;

    my $id   = $request->minion_id;
    my $tx   = $self->ua->get($self->url("status/$id"));
    my $err  = $self->_error('status', $tx);
    my $data = $tx->res->json // {};

    return OpenQA::CacheService::Response::Status->new(data => $data, error => $err);
}

sub enqueue {
    my ($self, $request) = @_;

    my $data = {task => $request->task, args => $request->to_array, lock => $request->lock};
    my $tx   = $self->ua->post($self->url('enqueue') => json => $data);
    if (my $err = $self->_error('enqueue', $tx)) { return $err }

    return 'Cache service enqueue error: Minion job id missing from response' unless my $id = $tx->res->json->{id};
    $request->minion_id($id);

    return undef;
}

sub _error {
    my ($self, $action, $tx) = @_;

    # Connection or server error
    if (my $err = $tx->error) {
        return "Cache service $action error $err->{code}: $err->{message}" if $err->{code};
        return "Cache service $action error: $err->{message}";
    }

    # Non-JSON response
    my $res  = $tx->res;
    my $code = $res->code;
    return "Cache service $action error: $code non-JSON response" unless my $json = $res->json;

    # API error
    return "Cache service $action error from API: $json->{error}" if $json->{error};

    return undef;
}

sub asset_path {
    my ($self, $host, $dir) = @_;
    $host = base_host($host);
    return path($self->cache_dir, $host, $dir);
}

sub asset_exists { -e shift->asset_path(@_) }

sub asset_request {
    my $self = shift;
    return OpenQA::CacheService::Request::Asset->new(@_);
}

sub rsync_request {
    my $self = shift;
    return OpenQA::CacheService::Request::Sync->new(@_);
}

sub url { Mojo::URL->new(shift->host)->path(shift)->to_string }

1;

=encoding utf-8

=head1 NAME

OpenQA::CacheService::Client - OpenQA Cache Service Client

=head1 SYNOPSIS

    use OpenQA::CacheService::Client;

    my $client = OpenQA::CacheService::Client->new(host=> 'http://127.0.0.1:9530', retry => 5, cache_dir => '/tmp/cache/path');
    my $request = $client->asset_request(id => 9999, asset => 'asset_name.qcow2', type => 'hdd', host => 'openqa.opensuse.org');
    $client->enqueue($request);
    until ($client->status($request)->is_processed) {
        say 'Waiting for asset download to finish';
        sleep 1;
    }
    say 'Asset downloaded!';

=head1 DESCRIPTION

OpenQA::CacheService::Client is the client used for interacting with the OpenQA Cache Service.

=cut
