package OpenQA::Cache;
use strict;
use warnings;


use File::Basename;
use Fcntl qw(:flock);
use Mojo::UserAgent;
use OpenQA::Utils qw(log_error log_info log_debug);
use OpenQA::Worker::Common;
use List::MoreUtils;
use Data::Dumper;
use Mojo::JSON qw(to_json from_json);

require Exporter;
our (@ISA, @EXPORT);
@ISA    = qw(Exporter);
@EXPORT = qw(get_asset);

my %cache;
my $host;
my $limit   = 5;
my $delete  = 0;
my $db_file = "../cache.db";

sub get {
    my ($asset) = @_;
    my $index = List::MoreUtils::first_index { $_ eq $asset } @{$cache{$host}};
    splice @{$cache{$host}}, $index, 1;
    unshift @{$cache{$host}}, $asset;
    expire_asset();
}

sub set {
    my ($asset) = @_;
    unshift @{$cache{$host}}, $asset;
    expire_asset();
}

sub init {
    my $class;
    $host = shift;
    @{$cache{$host}} = read_db();
    log_debug(__PACKAGE__ . ": Initialized with $host");
    log_debug(Dumper(\%cache));
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
    # $asset =~ s/share\///;
    log_debug "Attemping to download: $host $asset, $type, $id";
    my $ua = Mojo::UserAgent->new(max_redirects => 5);
    $ua->max_response_size(0);    #set initial filesize of 20GB
    my $tx = $ua->build_tx(GET => sprintf '%s/tests/%d/asset/%s/%s', $host, $id, $type, basename($asset));

    log_debug "Set up the transaction";
    open(my $log, '>>', "autoinst-log.txt") or die("Cannot open autoinst-log.txt");
    local $| = 1;
    print $log "CACHE: Locking $asset";

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
                        log_debug($progress . " < " . $current);
                        $last_updated = time;
                        if ($progress < $current) {
                            $progress = $current;
                            print $log "Downloading $asset :", $size == $len ? 100 : $progress, "\n";
                        }
                    }
                });
        });

    $tx = $ua->start($tx);
    log_debug("saving to $asset");
    print $log "CACHE: " . basename($asset) . " download sucessful";
    close($log);
    $tx->res->content->asset->move_to($asset);

}

sub get_asset {
    my ($job, $asset_type, $asset) = @_;
    my $type;
    $asset =~ s/share\///;
    # repo, kernel, and initrd should be also accepted here.
    $asset_type = (split /^(ISO|HDD)/, $asset_type)[1];

    while () {
        log_debug "Trying to aquire lock";
        open(my $asset_fd, ">", $asset . ".lock");

        if (!flock($asset_fd, LOCK_EX | LOCK_NB)) {
            update_setup_status $job->{id};
            log_debug("Asked to wait for lock, sleeping 10 secs");
            sleep 10;
            next;
        }

        if (-e $asset) {
            $type = "Cache Hit";
            get($asset);
        }
        else {
            $type = "Cache Miss";
            download_asset($job->{id}, lc($asset_type), $asset);
            set($asset);
        }
        write_db();
        flock($asset_fd, LOCK_UN);
        last;

    }

    unlink($asset . ".lock") or log_debug("Lock file for " . basename($asset) . " is not present");
    log_debug "got $type " . basename($asset);

}

sub purge_cache {
    log_debug("Expiring all the assets");
    map { expire_asset($_) } @{$cache{$host}};
}

sub expire_asset {
    if (@{$cache{$host}} > $limit) {
        my $asset = pop(@{$cache{$host}});
        unlink($asset) if $delete;
        log_debug("Purged $asset");
    }
}

sub write_db {
    open(my $file, ">", $db_file);
    flock($file, LOCK_EX);
    print $file to_json(\%cache);
    close($file);
    flock($file, LOCK_UN);
    log_debug("Wrote db file");
}

sub read_db {
    open(my $file, "<", $db_file);

    flock($file, LOCK_EX);
    my $data;
    while (<$file>) {
        $data .= $_;
    }

    %cache = \from_json($data);
    log_debug(Dumper(\%cache));

    close($file);
    flock($file, LOCK_UN);
    log_debug("Wrote db file");
}

1;
