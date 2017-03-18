package OpenQA::Cache;
use strict;
use warnings;

use File::Basename;
use Fcntl qw(:flock);
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
my $remove  = 1;
my $db_file = "../cache.db";

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
    @{$cache->{$host}} = read_db();
    log_debug(__PACKAGE__ . ": Initialized with $host at $location");
}

sub update_setup_status {
    my $id = @_;
    my $status = {setup => 1};
    api_call(
        'post',
        'jobs/' . $job->{id} . '/status',
        json     => {status => $status},
        callback => "no",
    );
    log_debug("Update status so job is not considered dead.");
}

sub download_asset {
    my ($id, $type, $asset) = @_;

    open(my $log, '>>', "autoinst-log.txt") or die("Cannot open autoinst-log.txt");
    local $| = 1;
    print $log "CACHE: Locking $asset\n";

    print $log "Attemping to download: $host $asset, $type, $id\n";
    my $ua = Mojo::UserAgent->new(max_redirects => 2);
    $ua->max_response_size(0);    #set initial filesize of 20GB
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
                        update_setup_status $id;
                        $last_updated = time;
                        if ($progress < $current) {
                            $progress = $current;
                            print $log "Downloading $asset :", $size == $len ? 100 : $progress, "\n";
                        }
                    }
                });
        });

    $tx = $ua->start($tx);
    print $log "CACHE: " . basename($asset) . " download sucessful\n";
    $asset = $tx->res->content->asset->move_to($asset);
    close($log);
    return $asset;

}

sub get_asset {
    my ($job, $asset_type, $asset) = @_;
    my $type;

    # repo, kernel, and initrd should be also accepted here.
    $asset_type = (split /^(ISO|HDD)/, $asset_type)[1];
    $asset = catdir($location, $asset);

    while () {
        read_db();
        log_debug "CACHE: Aquiring lock";
        open(my $asset_fd, ">", $asset . ".lock");

        if (!flock($asset_fd, LOCK_EX | LOCK_NB)) {
            update_setup_status $job->{id};
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
            download_asset($job->{id}, lc($asset_type), $asset);
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

sub purge_cache {
    log_debug("Expiring all the assets");
    map { expire_asset($_) } @{$cache->{$host}};
    write_db();
}

sub expire_asset {
    # currently only
    while (@{$cache->{$host}} > $limit) {
        my $asset = pop(@{$cache->{$host}});
        unlink($asset) if $remove;
        log_debug("Purged $asset due to $limit");
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
