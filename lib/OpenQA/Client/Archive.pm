package OpenQA::Client::Archive;
use strict;
use warnings;
use Data::Dump;

use JSON;
use Mojo::URL;
use Mojo::File 'path';

our $client;
our %options;
our $job;
our $path;

sub run {
    #We're only taking one argument
    ($client, %options) = @_;
    my $method = 'get';

    my $url = $options{url}->clone;
    $url->path->merge('details');
    my $req = $client->$method($url);
    my $res = $req->res;

    if ($res->code eq 200) {
        $job = $res->json->{job};
        #We have a job now, make a directory in $pwd by default
        $path = path($options{archive} || $job->{name})->make_path;
        chdir($path);
        #we can't backup repos, so don't even try
        delete($job->{assets}->{repos});
        download_assets() unless $options{'skip-download'};
        download_test_results(@{$job->{testresults}});
    }
    else {
        die "There's an error openQA client returned ", $res->code;
    }
}

sub _download_test_result_details {
    my $module = shift;
    my $url    = $options{url}->clone;
    my $ua     = $client;
    if ($module->{screenshot}) {
        #same structure is used for thumbnails and screenshots
        my $dir = $module->{'md5_dirname'} || ($module->{'md5_1'} . '/' . $module->{'md5_2'});

        $url->path(sprintf '/image/%s/%s', $dir, $module->{md5_basename});
        $ua->get($url)->res->content->asset->move_to('testresults/' . $module->{screenshot});

        if ($options{'with-thumbnails'}) {
            path('testresults/thumbnails')->make_path;
            $url->path('/image/', $dir, '/.thumbs/', $module->{md5_basename});
            $ua->get($url)->res->content->asset->move_to('testresults/thumbnails/' . $module->{md5_basename});
        }

    }
    elsif ($module->{text}) {
        my $file = Mojo::File->new('testresults', $module->{text});
        $file->spurt($module->{text_data} // "No data\n");
    }
}

sub download_test_results {
    my @testresults = @_;
    my $resultdir   = path('testresults')->make_path;
    for my $test (@testresults) {
        my $filename = "details-" . $test->{name};
        open(my $fh, ">", $resultdir->path . "/details-" . $test->{name} . ".json");
        $fh->print(encode_json($test));
        close($fh);
        map { _download_test_result_details($_) } @{$test->{details}};
    }

}

sub download_asset {
    # local $/;
    # $client->clone;
    my ($jobid, $type, $file) = @_;
    my $url = $options{url}->clone;
    my $ua  = $client;
    $ua->max_response_size(0);
    local $| = 1;
    $url->path(sprintf '/tests/%d/asset/%s/%s', $jobid, $type, $file);
    my $tx = $ua->build_tx(GET => $url);
    my $headers;

    #assume that we're in the working directory.
    path("$type")->make_path;
    die "can't write in $path/$type directory" unless -w "$type";
    $file = path("$type/$file");
    #Download progress monitor
    $ua->on(start => \&_progress_monitior);
    $ua->{filename} = $file;
    $tx = $ua->start($tx);
    my $code = ($tx->res->code) ? $tx->res->code : 521;    # Used by cloudflare to indicate web server is down.
    my $size;
    $| = 0;
    #fix the \r :)
    print "\n";
    if ($tx->res->is_server_error) {
        print("Could not download the asset $file.\n");
    }
    elsif ($tx->res->is_success) {
        my $size = $tx->res->content->asset->move_to($file)->size;
        print("CACHE: Asset download successful to $file.\n");
    }
    else {
        print("Unexpected error while downloading $file.\n");
    }

}

sub download_assets {
    my $asset_group;
    for $asset_group (keys %{$job->{assets}}) {
        map { download_asset($job->{id}, $asset_group, $_) } @{$job->{assets}{$asset_group}};
    }
}

sub _progress_monitior {

    my ($ua, $tx) = @_;
    my $progress = 0;
    print "We're here!";
    my $last_updated = time;
    my $filename     = $ua->{filename} // 'file';
    my $headers;

    print "We're here!";

    $tx->res->on(
        progress => sub {
            my $msg = shift;
            $msg->finish if $msg->code == 304;
            return unless my $len = $msg->headers->content_length;
            local $| = 1;
            my $size = $msg->content->progress;
            $headers = $msg->headers if !$headers;
            my $current = int($size / ($len / 100));
            $last_updated = time;
            if ($progress < $current) {
                $progress = $current;
                print("\rDownloading $filename: ", $size == $len ? 100 : $progress . "%");
            }
        });
}

1;
