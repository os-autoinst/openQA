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

use Mojo::File 'path';
has 'host';
has retrials => 5;
has cache_dir =>
  sub { $ENV{CACHE_DIR} || (OpenQA::Worker::Common::read_worker_config(undef, undef))[0]->{CACHEDIRECTORY} };

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
sub asset_exists { !!-e path(shift->cache_dir)->child(shift) }

sub enqueue_download {
    my ($self, $what) = @_;

    my $reply = $self->asset_download($what);

    # Safe states: Cache service is handling it
    return !!1
      if ($reply eq OpenQA::Worker::Cache::ASSET_STATUS_ENQUEUED)
      || ($reply eq OpenQA::Worker::Cache::ASSET_STATUS_DOWNLOADING)
      || ($reply eq OpenQA::Worker::Cache::ASSET_STATUS_IGNORE);

    return !!0;
}

sub processed {
    # When it is finished, it's done from the Cache service point of view,
    # as it's not in the queues anymore.
    # But from the client point of view,
    # or the file is there (successed), or is not there (failed processing)

    # Safe states
    return !!1 if shift->asset_download_info(shift) eq OpenQA::Worker::Cache::ASSET_STATUS_PROCESSED;
    return !!0;
}

sub info { $_[0]->get(join('/', shift->host, "info")) }
sub available { shift->info->success }

sub session_token { shift->_q('session_token') }

sub _q {
    my ($self, $q) = @_;
    _status(_retry(sub { $self->get(join('/', $self->host, $q)) } => $self->retrials));
}
sub _p {
    my ($self, $q, $j) = @_;
    _status(_retry(sub { $self->post(join('/', $self->host, $q) => json => $j) } => $self->retrials));
}

!!42;
