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

package OpenQA::Worker::Cache::Request {

    use Mojo::Base -base;
    use Carp 'croak';
    use OpenQA::Worker::Cache::Client;

    has 'task';
    has client => sub { OpenQA::Worker::Cache::Client->new };

    sub asset { OpenQA::Worker::Cache::Request::Asset->new(client => shift->client, @_,) }
    sub rsync { OpenQA::Worker::Cache::Request::Sync->new(client => shift->client, @_,) }

    sub execute_task { $_[0]->client->execute_task(shift) }
    sub status       { $_[0]->client->status(shift) }
    sub processed    { $_[0]->client->processed(shift) }
    sub output       { $_[0]->client->output(shift) }
    sub result       { $_[0]->client->result(shift) }
    sub enqueue      { $_[0]->client->enqueue(shift) }

    sub lock    { croak 'Not implemented in ' . __PACKAGE__ }
    sub to_hash { croak 'Not implemented in ' . __PACKAGE__ }
};

package OpenQA::Worker::Cache::Request::Asset {

    use Mojo::Base 'OpenQA::Worker::Cache::Request';

    # See task OpenQA::Cache::Task::Asset
    my @FIELDS = qw(id type asset host);
    has [@FIELDS];
    has task => 'cache_asset';

    sub lock {
        my $self = shift;
        join('.', map { $self->$_ } @FIELDS);
    }
    sub to_hash { {id => $_[0]->id, type => $_[0]->type, asset => $_[0]->asset, host => $_[0]->host} }
    sub to_array { $_[0]->id, $_[0]->type, $_[0]->asset, $_[0]->host }

};

package OpenQA::Worker::Cache::Request::Sync {

    use Mojo::Base 'OpenQA::Worker::Cache::Request';

    # See task OpenQA::Cache::Task::Sync
    my @FIELDS = qw(from to);
    has [@FIELDS];
    has task => 'cache_tests';

    sub lock {
        my $self = shift;
        join('.', map { $self->$_ } @FIELDS);
    }
    sub to_hash { {from => $_[0]->from, to => $_[0]->to} }
    sub to_array { $_[0]->from, $_[0]->to }

};

=encoding utf-8

=head1 NAME

OpenQA::Worker::Cache::Request - OpenQA Cache Service Request Object

=head1 SYNOPSIS

    use OpenQA::Worker::Cache::Client;

    my $client = OpenQA::Worker::Cache::Client->new( host=> 'http://127.0.0.1:7844', retry => 5, cache_dir => '/tmp/cache/path' );
    my $request = $client->request->asset( id => 9999, asset => 'asset_name.qcow2', type  => 'hdd', host  => 'openqa.opensuse.org' );
    $request->enqueue

    if ($request->processed && $client->asset_exists('asset_name.qcow2')) {
      print "Success";
    }

    my $request = $client->request->rsync( from => 'source', to => 'destination');

    ... $request->enqueue


=head1 DESCRIPTION

OpenQA::Worker::Cache::Request is the OpenQA Cache Service Request object, which is holding
the Minion Tasks information to dispatch a remote

=cut

!!42;
