# Copyright (C) 2017 SUSE LLC
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
use OpenQA::Utils qw(log_error log_info log_debug);
use OpenQA::Worker::Common;
use List::MoreUtils;
use File::Spec::Functions 'catdir';
use Data::Dumper;
use JSON;

require Exporter;
our (@ISA, @EXPORT);
@ISA    = qw(Exporter);
@EXPORT = qw(get_asset);

my $cache;
my $host;
my $location;
my $limit   = 50;
my $db_file = "cache.db";

sub get {
    my ($asset) = @_;
    my $index = List::MoreUtils::first_index { $_ eq $asset } @{$cache->{$host}};
    splice @{$cache->{$host}}, $index, 1 if @{$cache->{$host}} > 0;
    unshift @{$cache->{$host}}, $asset;
    expire_asset();
}

sub set {
    my ($asset) = @_;
    unshift @{$cache->{$host}}, $asset;
    get($asset);
}

sub init {
    my $class;
    ($host, $location) = @_;
    $db_file = catdir($location, $db_file);
    @{$cache->{$host}} = read_db();
    log_debug(__PACKAGE__ . ": Initialized with $host at $location");
}

sub download_asset {
    my ($id, $type, $asset) = @_;

    open(my $log, '>>', "autoinst-log.txt") or die("Cannot open autoinst-log.txt");
    local $| = 1;
    print $log "CACHE: Locking $asset\n";

    print $log "Attemping to download: $host $asset, $type, $id\n";
    my $ua = Mojo::UserAgent->new(max_redirects => 2);
    $ua->max_response_size(0);
    my $tx = $ua->build_tx(GET => sprintf '%s/tests/%d/asset/%s/%s', $host, $id, $type, basename($asset));

    $ua->on(
        start => sub {
            my ($ua, $tx) = @_;
            my $progress     = 0;
            my $last_updated = time;
            $tx->res->on(
                progress => sub {
                    my $msg = shift;
                    return unless my $len = $msg->headers->content_length;
                    my $size = $msg->content->progress;
                    my $current = int($size / ($len / 100));
                    local $| = 1;
                    # Don't spam the webui, update only every 5 seconds
                    if (time - $last_updated > 5) {
                        update_setup_status;
                        $last_updated = time;
                        if ($progress < $current) {
                            $progress = $current;
                            print $log "Downloading $asset :", $size == $len ? 100 : $progress, "\n";
                        }
                    }
                });
        });

    $tx = $ua->start($tx);
    if (!$tx->res->is_success) {
        printf $log "CACHE: download of %s failed with %d: %s\n", basename($asset), $tx->res->code, $tx->res->message;
        return undef;
    }
    else {
        print $log "CACHE: " . basename($asset) . " download sucessful\n";
        $asset = $tx->res->content->asset->move_to($asset);
    }
    close($log);
    return $asset;
}

sub get_asset {
    my ($job, $asset_type, $asset) = @_;
    my $type;

    $asset = catdir($location, $asset);

    while () {
        read_db();
        log_debug "CACHE: Aquiring lock";
        open(my $asset_fd, ">", $asset . ".lock");

        if (!flock($asset_fd, LOCK_EX | LOCK_NB)) {
            update_setup_status;
            log_debug("CACHE: Asked to wait for lock, sleeping 10 secs");
            sleep 10;
            next;
        }

        if (-s $asset) {
            $type = "Cache Hit";
            get($asset);
        }
        else {
            $type = "Cache Miss";
            my $ret = download_asset($job->{id}, lc($asset_type), $asset);
            if (!$ret) {
                unlink($asset . ".lock");
                return undef;
            }
            set($asset);
        }

        write_db();
        close($asset_fd);
        last;
    }

    unlink($asset . ".lock") or log_debug("Lock file for " . basename($asset) . " is not present");
    log_debug "$type for: " . basename($asset);
    return $asset;
}

sub expire_asset {
    # currently only
    while (@{$cache->{$host}} > $limit) {
        my $count = @{$cache->{$host}};
        my $asset = pop(@{$cache->{$host}});
        if (-e $asset) {
            unlink($asset);
            if ($@) {
                log_error("Cannot purge $asset: $@");
            }
            else {
                log_debug("Purged $asset due to assets in cache ($count) being over $limit");
            }
        }
        else {
            log_debug("$asset does not exist, reference has been removed from the cache");
        }
    }
    write_db();
}

sub write_db {
    open(my $fh, ">", $db_file);
    flock($fh, LOCK_EX);
    truncate($fh, 0) or die "cannot truncate $db_file: $!\n";
    my $json = JSON->new->pretty->canonical;
    print $fh $json->encode($cache);
    close($fh);
    log_debug("Saving cache db file");
    read_db();
}

sub read_db {

    local $/;    # use slurp mode to read the whole file at once.
    $cache = {};
    if (-e $db_file) {
        open(my $fh, "<", $db_file) or die "$db_file could not be created";
        flock($fh, LOCK_EX);
        eval { $cache = JSON->new->relaxed->decode(<$fh>) };

        log_debug "parse error in $db_file:\n$@" if $@;
        log_debug("Objects in the cache: ");
        log_debug(Dumper($cache));
        close($fh);
        log_debug("Read cache db file");
    }
    else {
        log_debug "Creating empty cache";
        write_db;
    }
}

1;
