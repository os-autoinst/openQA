# Copyright (C) 2017-2018 SUSE LLC
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

package OpenQA::Worker::Cache;
use strict;
use warnings;

use File::Basename;
use Fcntl ':flock';
use Mojo::UserAgent;
use OpenQA::Utils
  qw(log_error log_info log_debug get_channel_handle add_log_channel append_channel_to_defaults remove_channel_from_defaults);
use OpenQA::Worker::Common;
use List::MoreUtils;
use File::Spec::Functions 'catdir';
use File::Path qw(remove_tree make_path);
use Data::Dumper;
use Cpanel::JSON::XS;
use Mojo::SQLite;
use Mojo::File 'path';
use Mojo::Base -base;
use POSIX;

use constant ASSET_STATUS_PROCESSED   => 001;
use constant ASSET_STATUS_ENQUEUED    => 002;
use constant ASSET_STATUS_DOWNLOADING => 003;
use constant ASSET_STATUS_IGNORE      => 004;
use constant ASSET_STATUS_ERROR       => 005;

has [qw(host cache location db_file dsn dbh cache_real_size)];
has limit => 50 * (1024**3);
has sleep_time => 5;

sub new {
    shift->SUPER::new(@_)->init;
}

sub DESTROY {
    my $self = shift;

    $self->dbh->db->disconnect() if $self->dbh;
}

sub deploy_cache {
    my $self = shift;
    local $/;
    my $sql = <DATA>;
    log_info "Creating cache directory tree for " . $self->location;
    remove_tree($self->location, {keep_root => 1});
    path($self->location)->make_path;
    path($self->location, Mojo::URL->new($self->host)->host || $self->host)->make_path;
    path($self->location, 'tmp')->make_path;

    log_info "Deploying DB: $sql (dsn " . $self->dsn . ")";

    $self->dbh(Mojo::SQLite->new($self->dsn)) or die("Could not connect to the dbfile.");
    my $tx = $self->dbh->db->begin;
    $self->dbh->db->query($sql);
    $tx->commit;

    $self->dbh->db->disconnect;
}

sub init {
    my $self = shift;
    my ($host, $location) = ($self->host, $self->location);

    $self->db_file(path($location, 'cache.sqlite'));
    $self->dsn("sqlite:" . $self->db_file);
    $self->deploy_cache unless -e $self->db_file;
    $self->cache_real_size(0);
    $self->dbh(Mojo::SQLite->new($self->dsn));
    $self->cache_sync();
    #Ideally we only need $limit, and $need no extra space
    $self->check_limits(0);
    log_info(__PACKAGE__ . ": Initialized with $host at $location, current size is " . $self->cache_real_size);
    return $self;
}

sub cache_assets {

    my ($self, $job, $vars, $assetkeys) = @_;

    for my $this_asset (sort keys %$assetkeys) {
        log_debug("Found $this_asset, caching " . $vars->{$this_asset});
        my $asset = $self->get_asset($job, $assetkeys->{$this_asset}, $vars->{$this_asset});
        if ($this_asset eq 'UEFI_PFLASH_VARS' && !defined $asset) {
            log_error("Can't download $vars->{$this_asset}");
            # assume that if we have a full path, that's what we should use
            $vars->{$this_asset} = $vars->{$this_asset} if (-e $vars->{$this_asset});
            # don't kill the job if the asset is not found
            next;
        }
        return {error => "Can't download $vars->{$this_asset}"} unless $asset;
        unlink basename($asset) if -l basename($asset);
        symlink($asset, basename($asset)) or die "cannot create link: $asset, $pooldir";
        $vars->{$this_asset} = catdir(getcwd, basename($asset));
    }
    return undef;
}

sub download_asset {
    my $self = shift;
    my ($id, $type, $asset, $etag) = @_;

    if (get_channel_handle('autoinst')) {
        append_channel_to_defaults('autoinst');
    }
    else {
        add_log_channel('autoinst', path => 'autoinst-log.txt', level => 'debug', default => 'append');
    }

    my $ua = Mojo::UserAgent->new(max_redirects => 2);
    $ua->max_response_size(0);
    my $url = sprintf '%s/tests/%d/asset/%s/%s', $self->host, $id, $type, basename($asset);
    log_info("Downloading " . basename($asset) . " from $url");
    my $tx = $ua->build_tx(GET => $url);
    my $headers;

    $ua->on(
        start => sub {
            my ($ua, $tx) = @_;
            my $progress     = 0;
            my $last_updated = time;
            if (-e $asset) {    # Assets might be deleted by a sysadmin
                $tx->req->headers->header('If-None-Match' => qq{$etag}) if $etag;
            }
            $tx->res->on(
                progress => sub {
                    my $msg = shift;
                    $msg->finish if $msg->code == 304;
                    return unless my $len = $msg->headers->content_length;

                    my $size = $msg->content->progress;
                    $headers = $msg->headers if !$headers;
                    my $current = int($size / ($len / 100));
                    # Don't spam the webui, update only every 5 seconds
                    if (time - $last_updated > 5) {
                        #        update_setup_status;
                        # XXX: This now needs to be done while waiting on client side for asset to be processed
                        $last_updated = time;
                        if ($progress < $current) {
                            $progress = $current;
                            log_debug("CACHE: Downloading $asset: ", $size == $len ? 100 : $progress . "%");
                        }
                    }
                });
        });

    $tx = $ua->start($tx);
    my $code = ($tx->res->code) ? $tx->res->code : 521;    # Used by cloudflare to indicate web server is down.
    my $size;
    if ($code eq 304) {
        if ($self->_update_asset_last_use($asset)) {
            log_debug("CACHE: Content has not changed, not downloading the $asset but updating last use");
        }
        else {
            log_debug("CACHE: Abnormal situation, code 304. Retrying download");
            $asset = 520;
        }
    }
    elsif ($tx->res->is_server_error) {
        log_debug("CACHE: Could not download the asset, triggering a retry for $code.");
        log_debug("CACHE: Abnormal situation, server error. Retrying download");
        $asset = $code;
    }
    elsif ($tx->res->is_success) {
        $etag = $headers->etag;
        unlink($asset);
        $self->cache_sync;
        my $size = $tx->res->content->asset->move_to($asset)->size;
        if ($size == $headers->content_length) {
            $self->check_limits($size);
            my $att = 0;
            my $ok;
            # This needs to go in to the database at any cost - we have the lock and we succeeded in download
            # We can't just throw it away if database locks.
            ++$att and sleep 1 and log_debug("CACHE: Error updating Cache: attempting again: $att")
              until ($ok = $self->update_asset($asset, $etag, $size)) || $att > 5;
            log_error("CACHE: FAIL Could not update DB - purging asset")
              and $self->purge_asset($asset)
              and $asset = undef
              unless $ok;
            log_debug("CACHE: Asset download successful to $asset, Cache size is: " . $self->cache_real_size) if $ok;
        }
        else {
            log_debug(
                "CACHE: Size of $asset differs, Expected: " . $headers->content_length . " / Downloaded: " . "$size");
            $asset = 598;    # 598 (Informal convention) Network read timeout error
        }
    }
    else {
        my $message = $tx->res->error->{message};
        log_debug("CACHE: Download of $asset failed with: $code - $message");
        $self->purge_asset($asset);
        $asset = undef;
    }
    remove_channel_from_defaults('autoinst');
    return $asset;
}

sub get_asset {
    my $self = shift;
    my ($job, $asset_type, $asset) = @_;
    my $type;
    my $result;
    my $ret;
    $asset = catdir($self->location, basename($asset));
    my $n = 5;
    while () {
        $self->track_asset($asset);    # Track asset - make sure it's in DB
        $result = $self->_asset($asset);
        local $@;
        eval {
            $ret
              = $self->download_asset($job->{id}, lc($asset_type), $asset, ($result->{etag}) ? $result->{etag} : undef);
        };
        if (!$ret) {
            $asset = undef;
            last;
        }
        elsif ($ret =~ /^5[0-9]{2}$/ && --$n) {
            log_debug "CACHE: Error $ret, retrying download for $n more tries";
            log_debug "CACHE: Waiting " . $self->sleep_time . " seconds for the next retry";

            sleep $self->sleep_time;
            next;
        }
        elsif (!$n) {
            log_debug "CACHE: Too many download errors, aborting";
            $asset = undef;
            last;
        }
        last;
    }
    return $asset;
}

sub _asset {
    my ($self, $asset) = @_;
    my $result = $self->dbh->db->select('assets', [qw(etag size last_use)], {filename => $asset})->hashes;

    return {} if $result->size == 0 || $@;
    return $result->first;
}

sub track_asset {
    my ($self, $asset) = @_;

    my $res;
    my $sql = "INSERT OR IGNORE INTO assets (filename, size, last_use) VALUES (?, 0,  strftime('%s','now'));";

    eval {
        my $tx = $self->dbh->db->begin('exclusive');
        $res = $self->dbh->db->query($sql, $asset)->arrays;
        $tx->commit;
    };
    if ($@) {
        log_error "track_asset: Failed: $@";
    }

    return !!0 if $res->size == 0 || $@;
    return !!1 if $res->size > 0;
}

sub _update_asset_last_use {
    my ($self, $asset) = @_;

    eval {
        my $tx  = $self->dbh->db->begin('exclusive');
        my $sql = q(UPDATE assets set last_use = strftime('%s','now') where filename = ?;);
        $tx->commit;
        $self->dbh->db->query($sql, $asset);
        $tx->commit;
    };

    if ($@) {
        log_error "Update asset failed: $@";
        return !!0;
    }

    log_info "CACHE: updating the $asset last usage";
    return !!1;
}

sub update_asset {
    my ($self, $asset, $etag, $size) = @_;
    eval {
        my $tx  = $self->dbh->db->begin('exclusive');
        my $sql = q(UPDATE assets set etag =? , size = ?, last_use = strftime('%s','now') where filename = ?;);
        $self->dbh->db->query($sql, $etag, $size, $asset);
        $tx->commit;
    };
    if ($@) {
        log_error "Update asset $asset failed. Rolling back $@";
    }
    else {
        log_info "CACHE: updating the $asset with $etag and $size";
    }

    my $result = $self->dbh->db->select('assets', [qw(etag size last_use filename)], {filename => $asset})->arrays;

    return !!0 if $result->size == 0 || $@;
    $self->increase($size) and return !!1 if $result->size == 1;
}

sub purge_asset {
    my ($self, $asset) = @_;
    eval {
        my $tx = $self->dbh->db->begin();
        $self->dbh->db->delete('assets', {filename => $asset});
        $tx->commit;
        if (-e $asset) {
            unlink($asset) or eval { log_error "CACHE: Could not remove $asset" if -e $asset };
            log_debug "CACHE: removed $asset";
        }
        else {
            log_debug "CACHE: requested to remove unnexistant asset $asset";
        }
    };

    if ($@) {
        log_error "purge_asset: $@";
        return !!0;
    }
    return !!1;
}

sub file_size { (stat(pop))[7] }

sub cache_sync {
    my $self     = shift;
    my $location = $self->location;
    my $ext;
    $ext .= "-o -name '*.$_' " for qw(qcow2 iso vhd vhdx);
    my @assets = `find $location -maxdepth 1 -type f -name '*.img' $ext`;
    chomp @assets;
    $self->cache_real_size(0);
    foreach my $file (@assets) {
        my $asset_size = $self->file_size($file);
        next if !defined $asset_size;
        $self->cache_real_size($self->cache_real_size + $asset_size) if $self->asset_lookup($file);
    }
}

sub asset_lookup {
    my ($self, $asset) = @_;
    my $sth;
    my $result;
    eval {
        my $tx = $self->dbh->db->begin('exclusive');
        $result = $self->dbh->db->select('assets', [qw(filename etag last_use size)], {filename => $asset});
        $tx->commit;
    };
    if ($@) {
        return !!0;
    }

    if ($result->arrays->size == 0) {
        log_info "CACHE: Purging non registered $asset";
        $self->purge_asset($asset);
        return !!0;
    }

    return !!1;
}

sub exceeds_limit { !!($_[0]->cache_real_size + $_[1] > $_[0]->limit) }
sub limit_reached { !!($_[0]->cache_real_size > shift->limit) }
sub decrease {
    my ($self, $size) = @_;
    log_debug "Current cache size: " . $self->cache_real_size;
    $self->cache_real_size(
        !defined $size ? $self->cache_real_size : $size > $self->cache_real_size ? 0 : $self->cache_real_size - $size);
    log_debug "Reclaiming " . $size . " from " . $self->cache_real_size . " to make space for " . $self->limit;
}

sub increase { $_[0]->cache_real_size($_[0]->cache_real_size + pop) }

sub expire {
    my ($self, $asset) = @_;
    eval {
        my $tx = $self->dbh->db->begin('exclusive');
        $self->dbh->db->update('assets', {last_use => 0}, {filename => $asset});
        $tx->commit;
    };

    if ($@) {
        log_error "Update asset $asset failed. Rolling back $@";
    }
}

sub check_limits {
    my ($self, $needed) = @_;
    my $dbh = $self->dbh->db;
    eval {
        my $sth = $dbh->select('assets', [qw(filename size last_use)], undef, {-asc => 'last_use'});
        while (my $asset = $sth->hash) {
            my $asset_size = $asset->{size} || $self->file_size($asset->{filename});
            $self->decrease($asset_size)
              if $self->exceeds_limit($needed) && $self->purge_asset($asset->{filename}) && defined $asset_size;
        }
    } if $self->exceeds_limit($needed) || $self->limit_reached;
    log_error "CACHE: check_limit failed: $@" if $@;
    log_debug "CACHE: Health: Real size: " . $self->cache_real_size . ", Configured limit: " . $self->limit;
}

1;

__DATA__
CREATE TABLE "assets" ( `etag` TEXT, `size` INTEGER, `last_use` DATETIME NOT NULL, `filename` TEXT NOT NULL UNIQUE, PRIMARY KEY(`filename`) );
