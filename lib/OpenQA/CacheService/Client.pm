# Copyright 2018-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CacheService::Client;
use Mojo::Base -base, -signatures;

use OpenQA::Worker::Settings;
use OpenQA::CacheService::Request::Asset;
use OpenQA::CacheService::Request::Sync;
use OpenQA::CacheService::Response::Info;
use OpenQA::CacheService::Response::Status;
use OpenQA::Utils qw(base_host service_port);
use Socket qw(AF_INET IPPROTO_TCP SOCK_STREAM pack_sockaddr_in inet_aton);
use Mojo::URL;
use Mojo::File 'path';

# Define sensible defaults to cover even a restarting openQA webUI host being
# down for up to 5m
has attempts => $ENV{OPENQA_CACHE_ATTEMPTS} // 60;
has sleep_time => $ENV{OPENQA_CACHE_ATTEMPT_SLEEP_TIME} // 5;
has host => sub { 'http://127.0.0.1:' . service_port('cache_service') };
has cache_dir => sub { $ENV{OPENQA_CACHE_DIR} || OpenQA::Worker::Settings->new->global_settings->{CACHEDIRECTORY} };
has ua => sub {
    my $ua = Mojo::UserAgent->new(inactivity_timeout => 300);

    # set PeerAddrInfo directly (in consistency with host property) to workaround getaddrinfo() being stuck in error
    # state "Address family for hostname not supported" for local connections (see poo#78390#note-38).
    # note: The socket_options function has only been added in Mojolicious 8.72. For older versions we still rely
    #       on the monkey_patch within the BEGIN block of Worker.pm. It could be removed when we stop supporting older
    #       Mojolicious versions.
    my %cache_service_address = (
        family => AF_INET,
        protocol => IPPROTO_TCP,
        socktype => SOCK_STREAM,
        addr => pack_sockaddr_in(service_port('cache_service'), inet_aton('127.0.0.1')));
    $ua->socket_options->{PeerAddrInfo} = [\%cache_service_address] if $ua->can('socket_options');
    return $ua;
};

sub set_port ($self, $port) {
    $self->ua->socket_options->{PeerAddrInfo}->[0]->{addr} = pack_sockaddr_in($port, inet_aton('127.0.0.1'))
      if $self->ua->can('socket_options');
}

sub info ($self) {
    my $tx = $self->_request('get', $self->url('info'));
    my $err = $self->_error('info', $tx);
    my $data = $tx->res->json // {};
    return OpenQA::CacheService::Response::Info->new(data => $data, error => $err);
}

sub status ($self, $request) {
    my $id = $request->minion_id;
    my $tx = $self->_request('get', $self->url("status/$id"));
    my $err = $self->_error('status', $tx);
    my $data = $tx->res->json // {};
    return OpenQA::CacheService::Response::Status->new(data => $data, error => $err);
}

sub enqueue ($self, $request) {
    my $data = {task => $request->task, args => $request->to_array, lock => $request->lock};
    my $tx = $self->_request('post', $self->url('enqueue'), json => $data);
    if (my $err = $self->_error('enqueue', $tx)) { return $err }

    return 'Cache service enqueue error: Minion job id missing from response' unless my $id = $tx->res->json->{id};
    $request->minion_id($id);

    return undef;
}

sub _error ($self, $action, $tx) {
    my $res = $tx->res;
    my $code = $res->code;
    my $json = $res->json;

    # Connection or server error
    if (my $err = $tx->error) {
        if ($err->{code}) {
            return "Cache service $action error from API: $json->{error}" if $json && $json->{error};
            return "Cache service $action error $err->{code}: $err->{message}";
        }
        return "Cache service $action error: $err->{message}";
    }
    else { return "Cache service $action error: $code non-JSON response" unless $json }

    return undef;
}

sub _request ($self, $method, @args) {

    # Retry on connection errors (but not 4xx/5xx responses)
    my $ua = $self->ua;
    my $n = $self->attempts;
    my $tx;
    while (1) {
        $tx = $ua->$method(@args);
        return $tx unless my $err = $tx->error;
        return $tx if $err->{code};
        last if --$n <= 0;
        sleep $self->sleep_time;
    }

    return $tx;
}

sub asset_path ($self, $host, $dir) {
    $host = base_host($host);
    return path($self->cache_dir, $host, $dir);
}

sub asset_exists ($self, @args) { -e $self->asset_path(@args) }

sub asset_request ($self, @args) { OpenQA::CacheService::Request::Asset->new(@args) }

sub rsync_request ($self, @args) { OpenQA::CacheService::Request::Sync->new(@args) }

sub url ($self, $path) { Mojo::URL->new($self->host)->path($path)->to_string }

1;

=encoding utf-8

=head1 NAME

OpenQA::CacheService::Client - OpenQA Cache Service Client

=head1 SYNOPSIS

    use OpenQA::CacheService::Client;

    my $client = OpenQA::CacheService::Client->new(
        host      => 'http://127.0.0.1:9530',
        attempts  => => 5,
        cache_dir => '/tmp/cache/path'
    );
    my $request = $client->asset_request(
        id    => 9999,
        asset => 'asset_name.qcow2',
        type  => 'hdd',
        host  => 'openqa.opensuse.org'
    );
    $client->enqueue($request);
    until ($client->status($request)->is_processed) {
        say 'Waiting for asset download to finish';
        sleep 1;
    }
    say 'Asset downloaded!';

=head1 DESCRIPTION

OpenQA::CacheService::Client is the client used for interacting with the OpenQA Cache Service.

=cut
