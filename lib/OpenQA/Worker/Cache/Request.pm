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

package OpenQA::Worker::Cache::Request;
use Mojo::Base -base;

use Carp 'croak';
use OpenQA::Worker::Cache::Client;

has [qw(task minion_id)];
has client => sub { OpenQA::Worker::Cache::Client->new };

sub execute_task { $_[0]->client->execute_task(shift) }
sub status       { $_[0]->client->status(shift) }
sub processed    { $_[0]->client->processed(shift) }
sub output       { $_[0]->client->output(shift) }
sub result       { $_[0]->client->result(shift) }
sub enqueue      { $_[0]->client->enqueue(shift) }

sub lock     { croak 'lock() not implemented in ' . __PACKAGE__ }
sub to_hash  { croak 'to_hash() not implemented in ' . __PACKAGE__ }
sub to_array { croak 'to_array() not implemented in ' . __PACKAGE__ }

=encoding utf-8

=head1 NAME

OpenQA::Worker::Cache::Request - OpenQA Cache Service Request Object

=head1 SYNOPSIS

    use OpenQA::Worker::Cache::Client;

    my $client = OpenQA::Worker::Cache::Client->new( host=> 'http://127.0.0.1:7844', retry => 5, cache_dir => '/tmp/cache/path' );
    my $request = $client->asset_request( id => 9999, asset => 'asset_name.qcow2', type  => 'hdd', host  => 'openqa.opensuse.org' );
    $request->enqueue

    if ($request->processed && $client->asset_exists('asset_name.qcow2')) {
      print "Success";
    }

    my $request = $client->rsync_request( from => 'source', to => 'destination');

    ... $request->enqueue


=head1 DESCRIPTION

OpenQA::Worker::Cache::Request is the OpenQA Cache Service Request object, which is holding
the Minion Tasks information to dispatch a remote request to the Cache Service.

=cut

1;
