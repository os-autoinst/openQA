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

package OpenQA::Worker::Cache::Client;

use Mojo::Base 'Mojo::UserAgent';
use OpenQA::Worker::Cache;
use OpenQA::Worker::Common;

use Mojo::URL;
use Mojo::File 'path';
has host  => 'http://127.0.0.1:7844';
has retry => 5;
has cache_dir =>
  sub { $ENV{CACHE_DIR} || (OpenQA::Worker::Common::read_worker_config(undef, undef))[0]->{CACHEDIRECTORY} };

sub _url { Mojo::URL->new(shift->host)->path(shift)->to_string }

sub _status {
    return !!0 unless my $st = $_[0]->result->json->{status} // shift->result->json->{session_token};
    return $st;
}

sub _result {
    eval { $_[0]->post($_[0]->_url('status') => json => {lock => pop})->result->json->{+pop()} }
}

sub _query {
    my ($self, $q) = @_;
    _status(_retry(sub { $self->get($self->_url($q)) } => $self->retry));
}

sub _post {
    my ($self, $q, $j) = @_;
    _status(_retry(sub { $self->post($self->_url($q) => json => $j) } => $self->retry));
}

sub _retry {
    my ($cb, $times) = @_;
    my $res;
    my $att = 0;
    $times ||= 0;

    do { ++$att and $res = $cb->() } until $res->success || $att >= $times;

    return $res;
}

sub _reply {
    (        ($_[0] eq OpenQA::Worker::Cache::STATUS_ENQUEUED)
          || ($_[0] eq OpenQA::Worker::Cache::STATUS_DOWNLOADING)
          || ($_[0] eq OpenQA::Worker::Cache::STATUS_IGNORE)) ? !!1 : !!0;
}

sub _dequeue_lock {
    !!(shift->_post(dequeue => {lock => pop}) eq OpenQA::Worker::Cache::STATUS_PROCESSED);
}

# TODO:
# Some of following methods should be inside the request objects and OpenQA::Worker::Cache::Request
# should handle a reference to the client.
# E.g. $request->status and $request->output instead of $client->status($request)

sub execute_task { shift->_post(execute_task => {task => $_[0]->task, args => [$_[0]->to_array], lock => $_[0]->lock}) }
sub status { $_[0]->_post(status => {lock => pop->lock}) }
sub processed { shift->status(shift) eq OpenQA::Worker::Cache::STATUS_PROCESSED ? !!1 : !!0 }
sub output { shift->_result(output => pop->lock) }
sub result { shift->_result(result => pop->lock) }
sub info   { $_[0]->get($_[0]->_url("info")) }
sub available { shift->info->success }
sub available_workers {
    $_[0]->available
      && ($_[0]->info->result->json->{active_workers} != 0 || $_[0]->info->result->json->{inactive_workers} != 0);
}
sub session_token { shift->_query('session_token') }
sub enqueue       { _reply(shift->execute_task(@_)) }

# TODO: This could go in a separate object (?)
sub asset_path { path(shift->cache_dir, @_ > 1 ? (OpenQA::Worker::Cache::_base_host($_[0]) || shift) : ())->child(pop) }
sub asset_exists { !!(-e shift->asset_path(@_)) }

=encoding utf-8

=head1 NAME

OpenQA::Worker::Cache::Client - OpenQA Cache Service Client

=head1 SYNOPSIS

    use OpenQA::Worker::Cache::Client;

    my $client = OpenQA::Worker::Cache::Client->new( host=> 'http://127.0.0.1:7844', retry => 5, cache_dir => '/tmp/cache/path' );
    my $request = OpenQA::Worker::Cache::Request->asset( id => 9999, asset => 'asset_name.qcow2', type  => 'hdd', host  => 'openqa.opensuse.org' );
    $client->enqueue($request)

    if ($client->processed($request) && $client->asset_exists('asset_name.qcow2')) {
      print "Success";
    }

=head1 DESCRIPTION

OpenQA::Worker::Cache::Client is the client used for interacting with the OpenQA Cache Service.

=head1 METHODS

OpenQA::Worker::Cache::Client inherits all methods from L<Mojo::UserAgent>
and implements the following new ones:

=head2 execute_task()

    use OpenQA::Worker::Cache::Client;
    my $result = OpenQA::Worker::Cache::Client->new->execute_task(task_name => $request);

    $result->success;

Perform blocking request to download the asset to the cache service
and return resulting L<Mojo::Transaction::HTTP> object.

=head2 enqueue()

    use OpenQA::Worker::Cache::Client;
    use OpenQA::Worker::Cache::Request;

    my $request = OpenQA::Worker::Cache::Request->asset( id => 9999, asset => 'asset_name.qcow2', type  => 'hdd', host  => 'openqa.opensuse.org' );
    my $bool = OpenQA::Worker::Cache::Client->new->enqueue($request);

Perform blocking request to download the asset to the Cache Service
and returns a boolean indicating the success or the failure of dispatching
the request to it.

=head2 processed()

    use OpenQA::Worker::Cache::Client;
    my $request = OpenQA::Worker::Cache::Request->asset( id => 9999, asset => 'asset_name.qcow2', type  => 'hdd', host  => 'openqa.opensuse.org' );

    my $bool = OpenQA::Worker::Cache::Client->new->processed($request);

Perform blocking request, it returns true if the request was processed by the Cache Service, false otherwise.

=head2 status()

    use OpenQA::Worker::Cache::Client;
    my $request = OpenQA::Worker::Cache::Request->asset( id => 9999, asset => 'asset_name.qcow2', type  => 'hdd', host  => 'openqa.opensuse.org' );

    my $status = OpenQA::Worker::Cache::Client->new->status({
        id    => 9999,
        asset => 'asset_name.qcow2',
        type  => 'hdd',
        host  => 'openqa.opensuse.org'
    });

Perform blocking request to the Cache Service and returns the downloading status.
Statuses can be among: OpenQA::Worker::Cache::STATUS_PROCESSED,
OpenQA::Worker::Cache::STATUS_DOWNLOADING, OpenQA::Worker::Cache::STATUS_IGNORE.

=head2 asset_path()

    use OpenQA::Worker::Cache::Client;

    my $status = OpenQA::Worker::Cache::Client->new->asset_path( 'localhost' => 'file.qcow2' );
    my $status = OpenQA::Worker::Cache::Client->new->asset_path( 'file.qcow2' );

Returns a L<Mojo::File> Object representing the absolute path of the asset.

=head2 asset_exists()

    use OpenQA::Worker::Cache::Client;

    my $bool = OpenQA::Worker::Cache::Client->new->asset_exists( 'localhost' => 'file.qcow2' );
    my $bool = OpenQA::Worker::Cache::Client->new->asset_exists( 'file.qcow2' );

Returns true if the asset can be resolved, false otherwise.

=head2 output()

    use OpenQA::Worker::Cache::Client;

    my $request = OpenQA::Worker::Cache::Request->asset( id => 9999, asset => 'asset_name.qcow2', type  => 'hdd', host  => 'openqa.opensuse.org' );
    my $output = OpenQA::Worker::Cache::Client->new->output( $request );

Returns a string which is the output of the Cache process inside the Minion worker.

=head2 result()

    use OpenQA::Worker::Cache::Client;

    my $request = OpenQA::Worker::Cache::Request->asset( id => 9999, asset => 'asset_name.qcow2', type  => 'hdd', host  => 'openqa.opensuse.org' );
    my $result = OpenQA::Worker::Cache::Client->new->result( $request );

Returns the task result of the Cache process inside the Minion worker.

=head2 info()

    use OpenQA::Worker::Cache::Client;

    my $info = OpenQA::Worker::Cache::Client->new->info();

Returns an hashref with Minion statistics, see L<https://metacpan.org/pod/Minion#stats>.

=head2 available()

    use OpenQA::Worker::Cache::Client;

    my $client = OpenQA::Worker::Cache::Client->new;
    $client->enqueue(...) if $client->available();

Returns true if the cache service is available, false otherwise.

=head2 available_workers()

    use OpenQA::Worker::Cache::Client;

    my $client = OpenQA::Worker::Cache::Client->new;
    $client->enqueue(...) if $client->available_workers() && $client->available_workers();

Returns true if the cache service have minions connected to handle the request, false otherwise.

=head2 session_token()

    use OpenQA::Worker::Cache::Client;

    my $token = OpenQA::Worker::Cache::Client->new->session_token;

Returns the session token. It is unique, and it is different between restarts.

=head1 ATTRIBUTES

OpenQA::Worker::Cache::Client inherits all attributes from L<Mojo::UserAgent>
and implements the following new ones:

=head2 host()

    use OpenQA::Worker::Cache::Client;

    my $client = OpenQA::Worker::Cache::Client->new( host=> 'localhost:9393' );

Represents the Cache Service host.

=head2 retry()

    use OpenQA::Worker::Cache::Client;

    my $client = OpenQA::Worker::Cache::Client->new( retry => 20 );

Sets the number of retries before giving up on requests against the Cache Service.

=head2 cache_dir()

    use OpenQA::Worker::Cache::Client;

    my $client = OpenQA::Worker::Cache::Client->new( cache_dir => '/tmp' );

Sets the default cache directory.

=cut

!!42;
