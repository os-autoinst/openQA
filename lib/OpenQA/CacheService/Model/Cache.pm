# Copyright (C) 2017-2019 SUSE LLC
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

package OpenQA::CacheService::Model::Cache;
use Mojo::Base -base;

use Carp 'croak';
use File::Basename;
use Fcntl ':flock';
use Mojo::UserAgent;
use OpenQA::Utils qw(base_host);
use OpenQA::Worker::Settings;
use Mojo::SQLite;
use Mojo::File 'path';
use Mojo::Log;
use POSIX;

has [qw(cache location dsn)];
has limit      => 50 * (1024**3);
has log        => sub { Mojo::Log->new };
has sleep_time => 5;
has sqlite     => sub { Mojo::SQLite->new };
has ua         => sub { Mojo::UserAgent->new(max_redirects => 2, max_response_size => 0) };

sub from_worker {
    my $class = shift;

    my $global_settings = OpenQA::Worker::Settings->new->global_settings;
    return $class->new(
        host     => 'localhost',
        location => ($ENV{OPENQA_CACHE_DIR} || $global_settings->{CACHEDIRECTORY}),
        exists $global_settings->{CACHELIMIT} ? (limit => int($global_settings->{CACHELIMIT}) * (1024**3)) : (), @_
    );
}

sub _deploy_cache {
    my $self = shift;

    my $location = $self->location;
    $self->log->info(qq{Creating cache directory tree for "$location"});
    path($location)->remove_tree({keep_root => 1});
    path($location, 'tmp')->make_path;
}

sub init {
    my $self = shift;

    my $location = $self->location;
    my $log      = $self->log;

    my $db_file = path($location, 'cache.sqlite');
    $self->sqlite->from_string("sqlite:$db_file");
    $self->_deploy_cache unless -e $db_file;
    eval { $self->sqlite->migrations->name('cache_service')->from_data->migrate };
    if (my $err = $@) {
        croak qq{Deploying cache database to "$db_file" failed}
          . qq{ (Maybe the file is corrupted and needs to be deleted?): $err};
    }

    $self->cache_sync;
    $self->_check_limits(0);
    $log->info(qq{Cache size of "$location" is $self->{cache_real_size}, with limit } . $self->limit);

    return $self;
}

sub _download_asset {
    my ($self, $host, $id, $type, $asset, $etag) = @_;

    my $log = $self->log;

    my $ua  = $self->ua;
    my $url = sprintf '%s/tests/%d/asset/%s/%s', $host, $id, $type, basename($asset);
    $log->info('Downloading "' . basename($asset) . qq{" from "$url"});

    # Keep temporary files on the same partition as the cache
    local $ENV{MOJO_TMPDIR} = path($self->location, 'tmp')->to_string;
    my $tx = $ua->build_tx(GET => $url);

    # Assets might be deleted by a sysadmin
    $tx->req->headers->header('If-None-Match' => qq{$etag}) if $etag && -e $asset;
    $tx = $ua->start($tx);

    my $res = $tx->res;
    my $ret;

    my $code = $res->code // 521;    # Used by cloudflare to indicate web server is down.
    if ($code eq 304) {
        $log->info(qq{Content of "$asset" has not changed, updating last use});
        $ret = 520 unless $self->_update_asset_last_use($asset);
    }

    elsif ($res->is_server_error) {
        $log->info(qq{Downloading "$asset" failed with server error $code});
        $ret = $code;
    }

    elsif ($res->is_success) {
        my $headers = $tx->res->headers;
        $etag = $headers->etag;
        unlink $asset;
        $self->cache_sync;
        my $size = $res->content->asset->move_to($asset)->size;
        if ($size == $headers->content_length) {
            $self->_check_limits($size);

            # This needs to go in to the database at any cost - we have the lock and we succeeded in download
            # We can't just throw it away if database locks.
            my $att = 0;
            my $ok;
            ++$att and sleep 1 and $log->info("Updating cache failed (attempt $att)")
              until ($ok = $self->_update_asset($asset, $etag, $size)) || $att > 5;

            if ($ok) { $log->info(qq{Download of "$asset" successful, new cache size is $self->{cache_real_size}}) }
            else {
                $log->error(qq{Purging "$asset" because updating the cache failed, this should never happen});
                $self->purge_asset($asset);
            }
        }
        else {
            $log->info(qq{Size of "$asset" differs, expected } . $headers->content_length . " but downloaded $size");
            $ret = 598;    # 598 (Informal convention) Network read timeout error
        }
    }
    else {
        my $message = $res->error->{message};
        $log->info(qq{Purging "$asset" because the download failed: $code - $message});
        $self->purge_asset($asset);
    }

    return $ret;
}

sub get_asset {
    my ($self, $host, $job, $asset_type, $asset) = @_;

    my $log = $self->log;

    my $location = path($self->location, base_host($host));
    $location->make_path unless -d $location;
    $asset = $location->child(path($asset)->basename);

    my $n = 5;
    while (1) {
        $self->track_asset($asset);    # Track asset - make sure it's in DB
        my $result = $self->asset($asset);

        my $ret;
        eval { $ret = $self->_download_asset($host, $job->{id}, lc($asset_type), $asset, $result->{etag}) };
        last unless $ret;

        if ($ret =~ /^5[0-9]{2}$/ && --$n) {
            my $time = $self->sleep_time;
            $log->info("Download error $ret, waiting $time seconds for next try ($n remaining)");
            sleep $time;
            next;
        }
        elsif (!$n) {
            $log->info('Too many download errors, aborting');
            last;
        }

        last;
    }
}

sub asset {
    my ($self, $asset) = @_;
    my $results = $self->sqlite->db->select('assets', [qw(etag size last_use)], {filename => $asset})->hashes;
    return $results->first || {};
}

sub track_asset {
    my ($self, $asset) = @_;

    eval {
        my $sql = "INSERT OR IGNORE INTO assets (filename, size, last_use) VALUES (?, 0, strftime('%s','now'))";
        $self->sqlite->db->query($sql, $asset)->arrays;
    };
    if (my $err = $@) { $self->log->error("Tracking asset failed: $err") }
}

sub _update_asset_last_use {
    my ($self, $asset) = @_;

    eval {
        my $sql = "UPDATE assets set last_use = strftime('%s','now') where filename = ?";
        $self->sqlite->db->query($sql, $asset);
    };
    if (my $err = $@) {
        $self->log->error("Updating last use failed: $err");
        return undef;
    }

    return 1;
}

sub _update_asset {
    my ($self, $asset, $etag, $size) = @_;

    my $log = $self->log;
    eval {
        my $db  = $self->sqlite->db;
        my $tx  = $db->begin('exclusive');
        my $sql = "UPDATE assets set etag = ?, size = ?, last_use = strftime('%s','now') where filename = ?";
        $db->query($sql, $etag, $size, $asset);
        $tx->commit;
    };
    if (my $err = $@) {
        $log->error("Updating asset failed: $err");
        return undef;
    }

    $log->info(qq{Size of "$asset" is $size, with ETag "$etag"});
    $self->_increase($size);

    return 1;
}

sub purge_asset {
    my ($self, $asset) = @_;

    my $log = $self->log;
    eval {
        $self->sqlite->db->delete('assets', {filename => $asset});
        if   (-e $asset) { $log->error(qq{Unlinking "$asset" failed: $!}) unless unlink $asset }
        else             { $log->debug(qq{Purging "$asset" failed because the asset did not exist}) }
    };
    if (my $err = $@) {
        $log->error(qq{Purging "$asset" failed: $err});
        return undef;
    }

    return 1;
}

sub cache_sync {
    my $self = shift;

    $self->{cache_real_size} = 0;
    my $location = readlink($self->location) // $self->location;
    my $assets
      = path($location)->list_tree({max_depth => 2})->map('to_string')->grep(qr/\.(?:img|qcow2|iso|vhd|vhdx)$/);
    foreach my $file ($assets->each) {
        $self->_increase(-s $file) if $self->asset_lookup($file);
    }
}

sub asset_lookup {
    my ($self, $asset) = @_;

    my $results = $self->sqlite->db->select('assets', [qw(filename etag last_use size)], {filename => $asset});

    if ($results->arrays->size == 0) {
        $self->log->info(qq{Purging "$asset" because the asset is not registered});
        $self->purge_asset($asset);
        return undef;
    }

    return 1;
}

sub _decrease {
    my ($self, $size) = (shift, shift // 0);
    if   ($size > $self->{cache_real_size}) { $self->{cache_real_size} = 0 }
    else                                    { $self->{cache_real_size} -= $size }
}

sub _increase { $_[0]{cache_real_size} += $_[1] }

sub _exceeds_limit { $_[0]->{cache_real_size} + $_[1] > $_[0]->limit }

sub _check_limits {
    my ($self, $needed) = @_;

    my $limit = $self->limit;
    my $log   = $self->log;

    if ($self->_exceeds_limit($needed)) {
        $log->info(
            "Cache size $self->{cache_real_size} + needed $needed exceeds limit of $limit, purging least used assets");
        eval {
            my $db      = $self->sqlite->db;
            my $results = $db->select('assets', [qw(filename size last_use)], undef, {-asc => 'last_use'});
            for my $asset ($results->hashes->each) {
                my $asset_size = $asset->{size} || -s $asset->{filename} || 0;
                $log->info(
                    qq{Purging "$asset->{filename}" because we need space for new assets, reclaiming $asset_size});
                $self->_decrease($asset_size) if $self->purge_asset($asset->{filename});
                last if !$self->_exceeds_limit($needed);
            }
        };
        if (my $err = $@) { $log->error("Checking cache limit failed: $err") }
    }
}

1;

__DATA__
@@ cache_service
-- 1 up
CREATE TABLE IF NOT EXISTS assets (
    `etag` TEXT,
    `size` INTEGER,
    `last_use` DATETIME NOT NULL,
    `filename` TEXT NOT NULL UNIQUE,
    PRIMARY KEY(`filename`)
);

-- 1 down
DROP TABLE assets;
