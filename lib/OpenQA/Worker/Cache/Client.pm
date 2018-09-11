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

has 'host';

sub _status {
    return !!0 unless my $st = $_[0]->result->json->{status} // shift->result->json->{session_token};
    return $st;
}

sub _retry {
    my ($cb, $times) = @_;
    my $res;
    my $att = 0;
    $times ||= 0;

    do { ++$att and $res = $cb->() } until $res->success || $att >= $times;

    return $res if $res->success;
    return !!0;
}

sub asset_status { my ($self, $asset) = @_; }
sub asset_download { shift->_p("download", pop) }
sub asset_download_info { shift->_q(join('/', "status", pop)) }

sub info { $_[0]->get(join('/', shift->host, "info")) }
sub available { shift->info->success }

sub session_token { shift->_q('session_token') }

sub _q {
    my @a = @_;
    _status(_retry(sub { $a[0]->get(join('/', shift(@a)->host, pop(@a))) } => 5));
}
sub _p {
    my @a = @_;
    _status(_retry(sub { $a[0]->post(join('/', shift(@a)->host, shift(@a)) => json => pop(@a)) } => 5));
}

!!42;
