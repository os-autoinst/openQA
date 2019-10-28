# Copyright (C) 2018-2019 SUSE LLC
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
use OpenQA::CacheService::Model::Cache qw(STATUS_PROCESSED STATUS_ENQUEUED STATUS_DOWNLOADING STATUS_IGNORE);
use OpenQA::CacheService::Request::Asset;
use OpenQA::CacheService::Request::Sync;
use OpenQA::Utils 'base_host';
use Mojo::URL;
use Mojo::File 'path';

has host      => 'http://127.0.0.1:7844';
has retry     => 5;
has cache_dir => sub { $ENV{OPENQA_CACHE_DIR} || OpenQA::Worker::Settings->new->global_settings->{CACHEDIRECTORY} };
has ua        => sub { Mojo::UserAgent->new };

sub _url { Mojo::URL->new(shift->host)->path(shift)->to_string }

sub _status {
    my $res  = shift;
    my $data = $res->result->json;
    return undef unless my $status = $data->{status} // $data->{session_token};
    return $status;
}

sub _result {
    my ($self, $field, $request) = @_;

    my $res = eval {
        $self->ua->post($self->_url('status') => json => {lock => $request->lock, id => $request->minion_id})
          ->result->json->{$field};
    };
    return "Cache service status error: $@" if $@;
    return $res;
}

sub _get {
    my ($self, $path) = @_;
    return _status(_retry(sub { $self->ua->get($self->_url($path)) } => $self->retry));
}

sub _post {
    my ($self, $path, $data) = @_;
    return _status(_retry(sub { $self->ua->post($self->_url($path) => json => $data) } => $self->retry));
}

sub _info {
    my $self = shift;
    return $self->ua->get($self->_url('info'));
}

sub _retry {
    my ($cb, $times) = @_;

    my $res;
    my $att = 0;
    $times ||= 0;
    do { ++$att and $res = $cb->() } until !$res->error || $att >= $times;

    return $res;
}

sub dequeue_lock {
    my ($self, $lock) = @_;
    return $self->_post(dequeue => {lock => $lock}) == STATUS_PROCESSED;
}

sub status {
    my ($self, $request) = @_;
    return $self->_post(status => {lock => $request->lock, id => $request->minion_id});
}

sub processed {
    my ($self, $request) = @_;
    return $self->status($request) == STATUS_PROCESSED;
}

sub output { shift->_result(output => @_) }
sub result { shift->_result(result => @_) }

sub available { !shift->_info->error }

sub available_workers {
    my $self = shift;
    return undef unless $self->available;
    return undef unless my $res = $self->_info->result->json;
    return $res->{active_workers} != 0 || $res->{inactive_workers} != 0;
}

sub session_token { shift->_get('session_token') }

sub enqueue {
    my ($self, $request) = @_;

    my $response = _retry(
        sub {
            $self->ua->post($self->_url('execute_task') => json =>
                  {task => $request->task, args => $request->to_array, lock => $request->lock});
        } => $self->retry
    );
    my $json = $response->result->json;
    $request->minion_id($json->{id}) if exists $json->{id};

    my $status = _status($response);
    return $status == STATUS_ENQUEUED || $status == STATUS_DOWNLOADING || $status == STATUS_IGNORE;
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

sub availability_error {
    my $self = shift;
    return 'Cache service not reachable'            unless $self->available;
    return 'No workers active in the cache service' unless $self->available_workers;
    return undef;
}

1;

=encoding utf-8

=head1 NAME

OpenQA::CacheService::Client - OpenQA Cache Service Client

=head1 SYNOPSIS

    use OpenQA::CacheService::Client;

    my $client = OpenQA::CacheService::Client->new(host=> 'http://127.0.0.1:7844', retry => 5, cache_dir => '/tmp/cache/path');
    my $request = $client->asset_request(id => 9999, asset => 'asset_name.qcow2', type => 'hdd', host => 'openqa.opensuse.org');
    $client->enqueue($request);
    until ($client->processed($request)) {
        say 'Waiting for asset download to finish';
        sleep 1;
    }
    say 'Asset downloaded!';

=head1 DESCRIPTION

OpenQA::CacheService::Client is the client used for interacting with the OpenQA Cache Service.

=cut
