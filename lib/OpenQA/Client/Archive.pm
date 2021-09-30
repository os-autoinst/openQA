# Copyright 2018-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Client::Archive;
use Mojo::Base 'OpenQA::Client::Handler';

use Mojo::File 'path';
use Mojo::URL;
use Carp 'croak';
use Mojo::JSON 'encode_json';

sub run {
    my ($self, $options) = @_;

    croak 'Options must be a HASH ref' unless ref $options eq 'HASH';
    croak 'Need a URL to download job information' unless $options->{url};

    my $url = Mojo::URL->new($options->{url});
    my $req = $self->client->get($url);
    my $res = $req->res;
    my $default_max_asset_size = 1024 * 1024 * 200;
    $options->{'asset-size-limit'} //= $default_max_asset_size;
    $self->client->max_response_size($options->{'asset-size-limit'});

    my $code = $res->code;
    die "There's an error openQA client returned $code" unless $code eq 200;

    my $job = $res->json->{job} || die("No job could be retrieved");

    # We have a job now, make a directory in $pwd by default
    my $path = path($options->{archive})->make_path;

    # We can't backup repos, so don't even try
    delete($job->{assets}->{repo});

    $path->child('testresults', 'thumbnails')->make_path if $options->{'with-thumbnails'};
    $self->_download_assets($url, $job, $path);
    $self->_download_test_results($url, $job, $path, $options);
}

sub _download_test_result_details {
    my ($self, $url, $path, $module, $options) = @_;

    my $ua = $self->client;
    if ($module->{screenshot}) {

        # Same structure is used for thumbnails and screenshots
        my @dirnames = map { /md5_[^basename]/ ? $_ : () } keys %{$module};

        # Check if module has images
        return 0 unless @dirnames;

        my $dir = $module->{'md5_dirname'} || ($module->{'md5_1'} . '/' . $module->{'md5_2'});
        $url->path("/image/$dir/$module->{md5_basename}");

        my $destination = $path->child('testresults', $module->{screenshot});
        my $tx = $ua->get($url)->res->content->asset->move_to($destination);

        if ($options->{'with-thumbnails'}) {
            $url->path("/image/$dir/.thumbs/$module->{md5_basename}");
            $ua->get($url)
              ->res->content->asset->move_to($path->child('testresults', 'thumbnails', $module->{md5_basename}));
        }

    }

    elsif ($module->{text}) {
        my $file = $path->child('testresults', $module->{text});
        $file->spurt($module->{text_data} // "No data\n");
    }
}

sub _download_file_at {
    my ($self, $url, $job, $file, $location) = @_;

    my $ua = $self->client;

    my $jobid = $job->{id};
    $url->path("/tests/$jobid/file/$file");
    $ua->on(start => \&_progress_monitior);
    $ua->{filename} = $file;

    my $tx = $ua->build_tx(GET => $url);
    $ua->start($tx);

    # fix the \r :)
    print "\n";
    my $destination = $location->child($file);
    _download_handler($tx, $destination);
}

sub _download_handler {
    my ($tx, $file) = @_;

    my $filename = $file->basename;

    my $message;
    if (my $err = $tx->error) {
        $message //= {message => "file not found.\n"} if $tx->error->{code} && $tx->error->{code} eq 404;
        $message //= {message => "Unexpected error while downloading: @{ [$tx->error->{message}]}\n"}
          if $tx->error->{message};
    }
    elsif ($tx->res->is_success && $tx->res->content->asset->move_to($file)) {
        $message = {success => 1, message => "Asset $filename successfully downloaded and moved to $file\n"};
    }
    else {
        warn $tx->req->url;
        $message //= {message => "Unexpected error while moving $file.\n"};
    }

    # Everything is an error, except when there is success
    print $message->{message};

}

sub _download_test_results {
    my ($self, $url, $job, $path, $options) = @_;

    my $resultdir = path($path, 'testresults')->make_path;
    my $resultdir_ulogs = $resultdir->child('ulogs')->make_path;

    print "Downloading test details and screenshots to $resultdir\n";
    for my $test (@{$job->{testresults}}) {
        my $filename = $resultdir->child("details-$test->{name}.json");
        $filename->spurt(encode_json($test));
        print "Saved details for $filename\n";
        $self->_download_test_result_details($url, $path, $_, $options) for @{$test->{details}};
    }

    print "Downloading logs\n";
    for my $test_log (@{$job->{logs}}) {
        $self->_download_file_at($url, $job, $test_log, $resultdir);
    }

    print "Downloading ulogs\n";
    for my $test_log (@{$job->{ulogs}}) {
        $self->_download_file_at($url, $job, $test_log, $resultdir_ulogs);
    }

}

sub _download_asset {
    my ($self, $url, $jobid, $path, $type, $file) = @_;

    my $ua = $self->client;

    # Assume that we're in the working directory
    my $destination_directory = $path->child($type)->make_path;
    die "can't write in $path/$type directory" unless -w "$destination_directory";
    $file = $destination_directory->child($file);

    # Ensure we are requesting the right file, so call basename
    $url->path("/tests/$jobid/asset/$type/" . $file->basename);

    # Attach the download monitor
    $ua->on(start => \&_progress_monitior);
    my $tx = $ua->build_tx(GET => $url);

    $ua->{filename} = $file;
    $tx = $ua->start($tx);

    # fix the \r :)
    print "\n";
    _download_handler($tx, $file);

}

sub _download_assets {
    my ($self, $url, $job, $path) = @_;

    for my $asset_group (keys %{$job->{assets}}) {
        print "Attempt $asset_group download:\n";
        $self->_download_asset($url, $job->{id}, $path, $asset_group, $_) for @{$job->{assets}{$asset_group}};
    }
}

sub _progress_monitior {
    my ($ua, $tx) = @_;

    my $progress = 0;
    my $last_updated = time;
    my $filename = $ua->{filename} // 'File';
    my $headers;
    my $limit = $ua->max_response_size;

    # Mojo::Messages seem to have a problem when the user wants to use a transaction
    # instead of a get to download files
    $tx->res->once(
        progress => sub {
            my $msg = shift;
            return unless my $len = $msg->headers->content_length;
            if ($limit && $msg->headers->content_length >= $limit) {
                $msg->error(
                    {message => path($filename)->basename . " exceeeds maximum size limit of $limit", code => 509});
            }
        });

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
