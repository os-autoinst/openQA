# Copyright (C) 2017-2020 SUSE LLC
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

sub _perform_integrity_check {
    return shift->sqlite->db->query('pragma integrity_check')->arrays->flatten->to_array;
}

sub _check_database_integrity {
    my ($self)           = @_;
    my $integrity_errors = $self->_perform_integrity_check;
    my $log              = $self->log;
    if (scalar @$integrity_errors == 1 && ($integrity_errors->[0] // '') eq 'ok') {
        $log->debug('Database integrity check passed');
        return undef;
    }
    $log->error('Database integrity check found errors:');
    $log->error($_) for @$integrity_errors;
    return $integrity_errors;
}

sub repair_database {
    my ($self, $db_file) = @_;
    $db_file //= $self->_locate_db_file;
    return undef unless -e $db_file;

    # perform some tests; try to provoke an error
    my $log = $self->log;
    $log->debug("Testing sqlite database ($db_file)");
    eval {
        # perform basic checks (table creation, integrity check)
        my $sqlite = $self->sqlite;
        my $db     = $sqlite->db;
        my $tx     = $db->begin('exclusive');
        $db->query('create table if not exists cache_write_test (test text)');
        $db->query('drop table cache_write_test');
        undef $tx;
        if (my $integrity_errors = $self->_check_database_integrity) {
            $log->error('Re-indexing and vacuuming broken database');
            # reindex to fix errors like "row 1 missing from index downloads_created"
            # and "wrong # of entries in index downloads_created"
            $db->query('reindex');
            # vacuum to clear-up messages like "Page 2923 is never used" from integrity check
            $db->query('vacuum');    # can not run vacuum in a transaction
            die "Unable to fix errors reported by integrity check\n" if $self->_check_database_integrity;
        }

        # test migration
        $sqlite->migrations->migrate;
    };

    # remove broken database
    if (my $err = $@) {
        $log->error("Purging cache directory because database has been corrupted: $err");
        $db_file->remove;
    }
}

sub init {
    my $self = shift;

    my ($db_file, $location) = $self->_locate_db_file;
    my $log = $self->log;

    # Try to detect and fix corrupted database
    $self->repair_database($db_file);

    unless (-e $db_file) {
        $log->info(qq{Creating cache directory tree for "$location"});
        $location->remove_tree({keep_root => 1});
        $location->child('tmp')->make_path;
    }
    eval { $self->sqlite->migrations->migrate };
    if (my $err = $@) {
        croak qq{Deploying cache database to "$db_file" failed}
          . qq{ (Maybe the file is corrupted and needs to be deleted?): $err};
    }

    # Take care of pending leftovers
    $self->_delete_pending_assets;

    return $self->refresh;
}

sub _realpath { path(shift->location)->realpath }

sub _locate_db_file {
    my ($self) = @_;

    my $location = $self->_realpath;
    return ($location->child('cache.sqlite'), $location);
}

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
            $self->_check_limits($size, {$asset => 1});

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
    my $results = $self->sqlite->db->select('assets', [qw(etag size last_use pending)], {filename => $asset})->hashes;
    return $results->first || {};
}

sub track_asset {
    my ($self, $asset) = @_;

    eval {
        my $db  = $self->sqlite->db;
        my $tx  = $db->begin('exclusive');
        my $sql = "INSERT INTO assets (filename, size, last_use) VALUES (?, 0, strftime('%s','now'))"
          . "ON CONFLICT (filename) DO UPDATE SET pending=1";
        $db->query($sql, $asset);
        $tx->commit;
    };
    if (my $err = $@) { $self->log->error("Tracking asset failed: $err") }
}

sub _update_asset_last_use {
    my ($self, $asset) = @_;

    eval {
        my $db  = $self->sqlite->db;
        my $tx  = $db->begin('exclusive');
        my $sql = "UPDATE assets set last_use = strftime('%s','now'), pending = 0 where filename = ?";
        $db->query($sql, $asset);
        $tx->commit;
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
        my $db = $self->sqlite->db;
        my $tx = $db->begin('exclusive');
        my $sql
          = "UPDATE assets set etag = ?, size = ?, last_use = strftime('%s','now'), pending = 0 where filename = ?";
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
        my $db = $self->sqlite->db;
        my $tx = $db->begin('exclusive');
        $db->delete('assets', {filename => $asset});
        $tx->commit;
        if (-e $asset) { $log->error(qq{Unlinking "$asset" failed: $!}) unless unlink $asset }
        else           { $log->debug(qq{Purging "$asset" failed because the asset did not exist}) }
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
    my ($self, $needed, $to_preserve) = @_;

    my $limit = $self->limit;
    my $log   = $self->log;

    if ($self->_exceeds_limit($needed)) {
        my $cache_size  = human_readable_size($self->{cache_real_size});
        my $needed_size = human_readable_size($needed);
        my $limit_size  = human_readable_size($limit);
        $log->info(
            "Cache size $cache_size + needed $needed_size exceeds limit of $limit_size, purging least used assets");
        eval {
            my $results
              = $self->sqlite->db->select('assets', [qw(filename size last_use)], {pending => '0'},
                {-asc => 'last_use'});
            for my $asset ($results->hashes->each) {
                my $filename = $asset->{filename};
                next if $to_preserve && $to_preserve->{$filename};
                my $asset_size = $asset->{size} || -s $filename || 0;
                my $reclaiming = human_readable_size($asset_size);
                $log->info(qq{Purging "$filename" because we need space for new assets, reclaiming $reclaiming});
                $self->_decrease($asset_size) if $self->purge_asset($filename);
                last                          if !$self->_exceeds_limit($needed);
            }
        };
        if (my $err = $@) { $log->error("Checking cache limit failed: $err") }
    }
}

sub _delete_pending_assets {
    my ($self) = @_;

    my $log = $self->log;
    eval {
        my $results = $self->sqlite->db->select('assets', [qw(filename pending)], {pending => '1'});
        for my $asset ($results->hashes->each) {
            my $filename = $asset->{filename};
            $log->info(qq{Purging "$filename" because it appears pending after service startup});
            $self->purge_asset($filename);
        }
    };
    if (my $err = $@) { $log->error("Checking for pending leftovers failed: $err") }
}

1;
