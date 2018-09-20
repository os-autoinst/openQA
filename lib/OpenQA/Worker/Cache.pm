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
use DBI;
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

    $self->dbh->disconnect() if $self->dbh;
}

sub deploy_cache {
    my $self = shift;
    local $/;
    my $sql = <DATA>;
    print STDOUT "\n\n\n\nINIT\n";
    log_info "Creating cache directory tree for " . $self->location;
    remove_tree($self->location, {keep_root => 1});
    path($self->location)->make_path;
    path($self->location, Mojo::URL->new($self->host)->host || $self->host)->make_path;
    path($self->location, 'tmp')->make_path;

    log_info "Deploying DB: $sql (dsn " . $self->dsn . ")";

    my $dbh
      = DBI->connect($self->dsn, undef, undef, {RaiseError => 1, PrintError => 1, AutoCommit => 0, sqlite_unicode => 1})
      or die("Could not connect to the dbfile.");
    $dbh->do($sql);
    $dbh->commit;
    $dbh->disconnect;
    $self->dbh($dbh);
}

sub init {
    my $self = shift;
    my ($host, $location) = ($self->host, $self->location);
    my $db_file = path($location, 'cache.sqlite');

    $self->db_file($db_file);
    my $dsn = "dbi:SQLite:dbname=$db_file";
    $self->dsn($dsn);
    $self->deploy_cache unless -e $db_file;
    $self->cache_real_size(0);
    $self->dbh(
        DBI->connect(
            $dsn, undef, undef,
            {
                sqlite_unicode      => 1,
                RaiseError          => 1,
                PrintError          => 1,
                AutoCommit          => 1,
                AutoInactiveDestroy => 1,
            })
          or die("Could not connect to the dbfile."));
    #  XXX: With autocommit enabled, rollback are useless, see: http://sqlite.org/lockingv3.html
    $self->cache_cleanup();
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
        my $size = $tx->res->content->asset->move_to($asset)->size;
        if ($size == $headers->content_length) {
            $self->check_limits($size);
            my $att = 0;
            my $ok;
            # This needs to go in to the database at any cost - we have the lock and we succeeded in download
            # We can't just throw it away if database locks.
            ++$att and sleep 1 and log_debug("CACHE: Error updating Cache: attempting again: $att")
              until $ok = $self->update_asset($asset, $etag, $size) || $att > 5;
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

sub toggle_asset_lock {
    my $self = shift;
    my ($asset, $toggle) = @_;

    my $dbh = $self->dbh;

    my $check = 1 - $toggle;
    my $sql
      = "UPDATE assets set downloading = ?, filename = ?, last_use = strftime('%s','now') where filename = ? and downloading = ?";
    my $res;
    eval {
        $dbh->do("BEGIN EXCLUSIVE");
        $res = $dbh->prepare($sql)->execute($toggle, $asset, $asset, $check);
        $dbh->commit or die $dbh->errstr;
    };

    if ($@) {
        log_error "toggle_asset_lock: Rolling back $@";
        eval { $dbh->rollback };
        log_error "Rolling back failed: $@" if $@;
    }

    return 0 if !defined $res || $res == 0 || $@;
    return 1 if defined $res && $res == 1;
}

sub _asset {
    my ($self, $asset) = @_;

    my $sql = "SELECT downloading, etag from assets where filename = ?";
    $self->dbh->prepare($sql);
    my $result = $self->dbh->selectrow_hashref($sql, undef, $asset);

    return {} unless $result;
    return $result;
}

sub try_lock_asset {
    my ($self, $asset) = @_;
    my $sth;
    my $sql;
    my $lock_granted = 0;
    my $result;

    my $dbh = $self->dbh;

    eval {
        $lock_granted = 1 if $self->toggle_asset_lock($asset, 1);
        $result = $self->_asset($asset);
        log_info "CACHE: Being downloaded by another worker, sleeping."
          if exists $result->{downloading} && $result->{downloading} == 1 && $lock_granted == 0;
    };
    log_error "try_lock_asset: Failed $@" if $@;

    return $result if $lock_granted;
    return !!0;
}

sub track_asset {
    my ($self, $asset) = @_;

    my $dbh = $self->dbh;
    my $res;
    my $sql
      = "INSERT OR IGNORE INTO assets (downloading,filename, size, last_use) VALUES (0, ?, 0,  strftime('%s','now'));";

    eval {
        $dbh->do("BEGIN EXCLUSIVE");
        $res = $dbh->prepare($sql)->execute($asset) or die $dbh->errstr;
        $dbh->commit or die $dbh->errstr;
    };

    if ($@) {
        log_error "track_asset: Failed: $@";
        eval { $dbh->rollback };
        log_error "Rolling back failed: $@";
    }

    return !!0 if !defined $res || $res == 0 || $@;
    return !!1 if defined $res;
}

sub _update_asset_last_use {
    my ($self, $asset) = @_;

    my $dbh = $self->dbh;
    $dbh->do("BEGIN EXCLUSIVE");

    my $sql = "UPDATE assets set last_use = strftime('%s','now') where filename = ?;";
    eval {
        my $sth = $dbh->prepare($sql);
        $sth->bind_param(1, $asset);
        $sth->execute;
        $dbh->commit;
    };

    if ($@) {
        log_error "Update asset failed. Rolling back $@";
        eval { $dbh->rollback };
        log_error "Rolling back failed: $@";
        return !!0;
    }

    log_info "CACHE: updating the $asset last usage";
    return !!1;
}

sub update_asset {
    my ($self, $asset, $etag, $size) = @_;

    my $dbh = $self->dbh;

    my $sql = "UPDATE assets set filename =?, etag =? , size = ?, last_use = strftime('%s','now') where filename = ?;";
    my $res;

    eval {
        $dbh->do('BEGIN EXCLUSIVE');
        my $sth = $dbh->prepare($sql);
        $sth->bind_param(1, $asset);
        $sth->bind_param(2, $etag);
        $sth->bind_param(3, $size);
        $sth->bind_param(4, $asset);

        $res = $sth->execute;
        $dbh->commit;
    };

    $self->cache_real_size($self->cache_real_size + $size);

    if ($@) {
        log_error "Update asset $asset failed. Rolling back $@";
        eval { $dbh->rollback };
        log_error "Rolling back failed: $@";
    }
    else {
        log_info "CACHE: updating the $asset with $etag and $size";
    }

    return !!0 if !defined $res || $res == 0 || $@;
    return !!1 if defined $res && $res == 1;
}

sub purge_asset {
    my ($self, $asset) = @_;
    my $sql = "DELETE FROM assets WHERE filename = ?";
    my $dbh = $self->dbh;

    eval {
        $dbh->do("BEGIN EXCLUSIVE");
        $dbh->prepare($sql)->execute($asset) or die $dbh->errstr;
        $dbh->commit or die $dbh->errstr;
        unlink($asset) or eval { log_error "CACHE: Could not remove $asset" if -e $asset };
        log_debug "CACHE: removed $asset";
    };

    if ($@) {
        log_error "purge_asset: Rolling back $@";
        eval { $dbh->rollback };
        log_error "Rolling back failed: $@";
        return !!0;
    }
    return !!1;
}

sub cache_cleanup {
    my $self     = shift;
    my $location = $self->location;
    my @assets
      = `find $location -maxdepth 1 -type f -name '*.img' -o -name '*.qcow2' -o -name '*.iso' -o -name '*.vhd' -o -name '*.vhdx'`;
    chomp @assets;
    foreach my $file (@assets) {
        my $asset_size = (stat $file)[7];
        next if !defined $asset_size;
        $self->cache_real_size($self->cache_real_size + $asset_size) if $self->asset_lookup($file);
    }
}

sub asset_lookup {
    my ($self, $asset) = @_;
    my $sth;
    my $sql;
    my $lock_granted;
    my $result;
    my $dbh = $self->dbh;

    eval {
        $dbh->do("BEGIN EXCLUSIVE");
        $sql    = "SELECT filename, etag, last_use, size from assets where filename = ?";
        $sth    = $dbh->prepare($sql);
        $result = $dbh->selectrow_hashref($sql, undef, $asset);
        $dbh->commit or die $dbh->errstr;
    };

    if ($@) {
        log_error "asset_lookup: Rolling back $@";
        eval { $dbh->rollback };
        log_error "Rolling back failed: $@";
        return !!0;
    }

    if (!$result) {
        log_info "CACHE: Purging non registered $asset";
        $self->purge_asset($asset);
        return !!0;
    }

    return $result;
}

sub check_limits {
    # Trust the filesystem.
    my ($self, $needed) = @_;
    my $sql;
    my $sth;
    my $result;
    my $dbh = $self->dbh;

    my $ret = 0;
    eval {
        while ($self->cache_real_size + $needed > $self->limit) {
            $sql    = "SELECT size, filename FROM assets WHERE downloading = 0 ORDER BY last_use asc";
            $sth    = $dbh->prepare($sql);
            $result = $dbh->selectrow_hashref($sql);
            do { log_error "There are no more elements to remove"; last } unless $result;

            foreach my $asset ($result) {
                if ($self->purge_asset($asset->{filename})) {
                    $self->cache_real_size($self->cache_real_size - $asset->{size});
                    log_debug "Reclaiming "
                      . $asset->{size}
                      . " from "
                      . $self->cache_real_size
                      . " to make space for "
                      . $self->limit;
                    $ret++;
                }    # purge asset will die anyway in case of failure.
                last if ($self->cache_real_size < $self->limit);
            }

        }
    };
    log_error "CACHE: check_limit failed: $@" if $@;
    log_debug "CACHE: Health: Real size: " . $self->cache_real_size . ", Configured limit: " . $self->limit;
    return $ret;
}

1;

__DATA__
CREATE TABLE "assets" ( `etag` TEXT, `size` INTEGER, `last_use` DATETIME NOT NULL, `downloading` boolean NOT NULL, `filename` TEXT NOT NULL UNIQUE, PRIMARY KEY(`filename`) );
