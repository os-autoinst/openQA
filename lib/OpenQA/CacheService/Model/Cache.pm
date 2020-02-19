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
use Mojo::URL;
use OpenQA::Utils qw(base_host human_readable_size);
use OpenQA::Downloader;
use Mojo::File 'path';

has downloader => sub { OpenQA::Downloader->new };
has [qw(location log sqlite)];
has limit => 50 * (1024**3);

sub init {
    my $self = shift;

    my $location = $self->_realpath;
    my $db_file  = $location->child('cache.sqlite');
    unless (-e $db_file) {
        $self->log->info(qq{Creating cache directory tree for "$location"});
        $location->remove_tree({keep_root => 1});
        $location->child('tmp')->make_path;
    }
    eval { $self->sqlite->migrations->migrate };
    if (my $err = $@) {
        croak qq{Deploying cache database to "$db_file" failed}
          . qq{ (Maybe the file is corrupted and needs to be deleted?): $err};
    }

    return $self->refresh;
}

sub _realpath { path(shift->location)->realpath }

sub refresh {
    my $self = shift;

    $self->_cache_sync;
    $self->_check_limits(0);
    my $cache_size = human_readable_size($self->{cache_real_size});
    my $limit_size = human_readable_size($self->limit);
    my $location   = $self->_realpath;
    $self->log->info(qq{Cache size of "$location" is $cache_size, with limit $limit_size});

    return $self;
}

sub get_asset {
    my ($self, $host, $job, $type, $asset) = @_;

    my $host_location = $self->_realpath->child(base_host($host));
    $host_location->make_path unless -d $host_location;
    $asset = $host_location->child(path($asset)->basename);

    my $file = path($asset)->basename;
    my $url  = Mojo::URL->new($host =~ m!^/|://! ? $host : "http://$host")->path("/tests/$job->{id}/asset/$type/$file");

    # Keep temporary files on the same partition as the cache
    my $log        = $self->log;
    my $downloader = $self->downloader->log($log)->tmpdir($self->_realpath->child('tmp')->to_string);

    my $options = {
        on_attempt   => sub { $self->track_asset($asset) },
        on_unchanged => sub {
            $log->info(qq{Content of "$asset" has not changed, updating last use});
            $self->_update_asset_last_use($asset);
        },
        on_downloaded => sub { $self->_cache_sync },
        on_success    => sub {
            my $res = shift;

            my $headers = $res->headers;
            my $etag    = $headers->etag;
            my $size    = $headers->content_length;
            $self->_check_limits($size);

            # This needs to go in to the database at any cost - we have the lock and we succeeded in download
            # We can't just throw it away if database locks.
            my $att = 0;
            my $ok;
            ++$att and sleep 1 and $log->info("Updating cache failed (attempt $att)")
              until ($ok = $self->_update_asset($asset, $etag, $size)) || $att > 5;

            if ($ok) {
                my $cache_size = human_readable_size($self->{cache_real_size});
                $log->info(qq{Download of "$asset" successful, new cache size is $cache_size});
            }
            else {
                $log->error(qq{Purging "$asset" because updating the cache failed, this should never happen});
                $self->purge_asset($asset);
            }
        },
        on_failed => sub {
            $log->info(qq{Purging "$asset" because of too many download errors});
            $self->purge_asset($asset);
        },
        etag => $self->asset($asset)->{etag}};

    $downloader->download($url, $asset, $options);
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

    my $asset_size = human_readable_size($size);
    $log->info(qq{Size of "$asset" is $asset_size, with ETag "$etag"});
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

sub _cache_sync {
    my $self = shift;

    $self->{cache_real_size} = 0;
    my $location = $self->_realpath;
    my $assets   = $location->list_tree({max_depth => 2})->map('to_string')->grep(qr/\.(?:img|qcow2|iso|vhd|vhdx)$/);
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
        my $cache_size  = human_readable_size($self->{cache_real_size});
        my $needed_size = human_readable_size($needed);
        my $limit_size  = human_readable_size($limit);
        $log->info(
            "Cache size $cache_size + needed $needed_size exceeds limit of $limit_size, purging least used assets");
        eval {
            my $db      = $self->sqlite->db;
            my $results = $db->select('assets', [qw(filename size last_use)], undef, {-asc => 'last_use'});
            for my $asset ($results->hashes->each) {
                my $asset_size = $asset->{size} || -s $asset->{filename} || 0;
                my $reclaiming = human_readable_size($asset_size);
                $log->info(
                    qq{Purging "$asset->{filename}" because we need space for new assets, reclaiming $reclaiming});
                $self->_decrease($asset_size) if $self->purge_asset($asset->{filename});
                last                          if !$self->_exceeds_limit($needed);
            }
        };
        if (my $err = $@) { $log->error("Checking cache limit failed: $err") }
    }
}

1;
