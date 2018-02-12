# Copyright (C) 2018 SUSE Linux Products GmbH
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package OpenQA::Client::Archive;
use Mojo::Base 'OpenQA::Client::Handler';

use Mojo::Exception;
use Mojo::File 'path';
use Mojo::URL;
use Carp 'croak';
use JSON;

use Data::Dump;

my $job;
my $path;
my $url;
my $options;

sub run {

    #We'he only taking one argument
    my ($self, $options) = @_;

    croak 'Options must be a HASH ref' unless ref $options eq 'HASH';
    croak 'Need a file to upload in the options!' unless $options->{url};

    $url = Mojo::URL->new($options->{url});
    my $req = $self->client->get($url);
    my $res = $req->res;

    if ($res->code eq 200) {
        $job = $res->json->{job} || die("No job could be retrieved");
        #We have a job now, make a directory in $pwd by default
        $path = path($options->{archive})->make_path;
        #we can't backup repos, so don't even try
        delete($job->{assets}->{repos});
        $path->path('testresults/thumbnails')->make_path if $options->{'with-thumbnails'};
        $self->download_assets unless $options->{'skip-download'};
        $self->download_test_results;
    }
    else {
        die "There's an error openQA client returned " . $res->code;
    }
}

sub _download_test_result_details {
    my ($self, $module) = @_;
    my $ua = $self->client;
    if ($module->{screenshot}) {
        #same structure is used for thumbnails and screenshots
        my @dirnames = map { /md5_[^basename]/ ? $_ : () } keys %{$module};
        # check if module has images
        return 0 unless @dirnames;

        my $dir = $module->{'md5_dirname'} || ($module->{'md5_1'} . '/' . $module->{'md5_2'});

        $url->path("/image/$dir/" . $module->{md5_basename});

        my $destination = $path->path('testresults/', $module->{screenshot});
        my $tx = $ua->get($url)->res->content->asset->move_to($destination);

        if ($options->{'with-thumbnails'}) {
            $url->path('/image/', $dir, '/.thumbs/', $module->{md5_basename});
            $ua->get($url)
              ->res->content->asset->move_to($path->path('testresults/thumbnails/', $module->{md5_basename}));
        }

    }
    elsif ($module->{text}) {
        my $file = Mojo::File->new($path->path('testresults/' . $module->{text}));
        $file->spurt($module->{text_data} // "No data\n");
    }
}

sub _download_file_at {

    my ($self, $file, $location) = @_;
    my $ua = $self->client;

    my $jobid = $job->{id};
    $url->path("/tests/$jobid/file/$file");
    $ua->on(start => \&_progress_monitior);
    $ua->{filename} = $file;

    my $tx = $ua->build_tx(GET => $url);
    $tx = $ua->start($tx);

    # fix the \r :)
    print "\n";
    my $destination = $location->path($file);
    _download_handler($tx, $destination);
}

sub _download_handler {
    my ($tx, $file) = @_;

    print("Unexpected error while downloading $file.\n") unless $tx;

    if ($tx->res->is_success && $tx->res->content->asset->move_to($file)) {
        print "File download successful to $file\n";
        return 1;
    }
    elsif ($tx->res->is_server_error) {
        print "Could not download the file $file.\n";
    }
    elsif ($tx->res->code == 404) {
        print "file not found.\n";
    }

    print "Unexpected error while moving $file.\n";

}

sub download_test_results {

    my ($self) = shift;
    my $resultdir = path($path, 'testresults')->make_path;
    my $resultdir_ulogs = $resultdir->path('ulogs')->make_path;

    print "Downloading test details and screenshots to $resultdir\n";
    for my $test (@{$job->{testresults}}) {
        my $filename = $resultdir->path . "/details-" . $test->{name} . ".json";
        open(my $fh, ">", $filename);
        $fh->print(encode_json($test));
        close($fh);
        print "Saved details for " . $filename . "\n";
        map { $self->_download_test_result_details($_) } @{$test->{details}};
    }

    print "Downloading logs\n";
    for my $test_log (@{$job->{logs}}) {
        $self->_download_file_at($test_log, $resultdir);
    }

    print "Downloading ulogs\n";
    for my $test_log (@{$job->{ulogs}}) {
        $self->_download_file_at($test_log, $resultdir_ulogs);
    }

}

sub download_asset {

    my ($self, $jobid, $type, $file) = @_;
    my $ua = $self->client;
    local $| = 1;

    # Override waitting time as big assets can take quite some time
    $url->path("/tests/$jobid/asset/$type/$file");
    my $tx = $ua->build_tx(GET => $url);
    my $headers;

    #assume that we're in the working directory.
    my $destination_directory = $path->path("$type")->make_path;
    die "can't write in $path/$type directory" unless -w "$destination_directory";
    $file = $destination_directory->path($file);

    #Download progress monitor
    $ua->on(start => \&_progress_monitior);

    $ua->{filename} = $file;
    $tx = $ua->start($tx);

    $| = 0;
    # fix the \r :)
    print "\n";
    _download_handler($tx, $file);

}

sub download_assets {
    my $self = shift;
    my $asset_group;
    for my $asset_group (keys %{$job->{assets}}) {
        print "Attempt $asset_group download:\n";
        map { download_asset($job->{id}, $asset_group, $_) } @{$job->{assets}{$asset_group}};
    }
}

sub _progress_monitior {

    my ($ua, $tx) = @_;
    my $progress     = 0;
    my $last_updated = time;
    my $filename     = $ua->{filename} // 'file';
    my $headers;

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
