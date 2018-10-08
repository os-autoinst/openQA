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

# TODO: This can go in a separate object.
sub asset_download { shift->_post("download", pop) }
sub asset_download_info { shift->_post(status => {asset => pop}) }
sub asset_path { path(shift->cache_dir, @_ > 1 ? (OpenQA::Worker::Cache::_base_host($_[0]) || shift) : ())->child(pop) }
sub asset_exists { !!(-e shift->asset_path(@_)) }

sub dequeue_job {
    !!(shift->_post(dequeue => {asset => pop}) eq OpenQA::Worker::Cache::ASSET_STATUS_PROCESSED);
}

sub enqueue_download {
    my ($self, $what) = @_;

    my $reply = $self->asset_download($what);
    (        ($reply eq OpenQA::Worker::Cache::ASSET_STATUS_ENQUEUED)
          || ($reply eq OpenQA::Worker::Cache::ASSET_STATUS_DOWNLOADING)
          || ($reply eq OpenQA::Worker::Cache::ASSET_STATUS_IGNORE)) ? !!1 : !!0;
}

sub processed {
    # When it is finished, it's done from the Cache service point of view,
    # as it's not in the queues anymore.
    # But from the client point of view,
    # or the file is there (successed), or is not there (failed processing)

    shift->asset_download_info(shift) eq OpenQA::Worker::Cache::ASSET_STATUS_PROCESSED ? !!1 : !!0;
}

sub asset_download_output {
    eval { $_[0]->post($_[0]->_url('status') => json => {asset => pop})->result->json->{output} }
}

sub info      { $_[0]->get($_[0]->_url("info")) }
sub available { shift->info->success }
sub available_workers {
    $_[0]->available
      && ($_[0]->info->result->json->{active_workers} != 0 || $_[0]->info->result->json->{inactive_workers} != 0);
}
sub session_token { shift->_query('session_token') }

*asset_status = \&asset_download;

!!42;
