# Copyright (C) 2018 SUSE LLC
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

package OpenQA::Task::Asset::Download;
use Mojo::Base 'Mojolicious::Plugin';

use OpenQA::Utils;
use Mojo::URL;
use Mojo::UserAgent;
use File::Basename;
use File::Spec::Functions qw(catfile splitpath);
use Archive::Extract;
use Try::Tiny;

sub register {
    my ($self, $app) = @_;
    $app->minion->add_task(download_asset => sub { _download($app, @_) });
}

sub _download {
    my ($app, $job, $url, $assetpath, $do_extract) = @_;

    # prevent multiple asset download tasks for the same asset to run
    # in parallel
    return $job->retry({delay => 30})
      unless my $guard = $app->minion->guard("limit_asset_download_${assetpath}_task", 7200);

    # bail if the dest file exists (in case multiple downloads of same ISO are scheduled)
    return undef if -e $assetpath;
    my $assetdir = (splitpath($assetpath))[1];
    OpenQA::Utils::log_fatal("asset download: cannot write to $assetdir") unless -w $assetdir;

    # check whether URL is whitelisted for download. this should never fail;
    # if it does, it means this task has been created without going
    # through the ISO API controller, and that means either a code
    # change we didn't think through or someone being evil
    if (my @check = OpenQA::Utils::check_download_url($url, $app->config->{global}->{download_domains})) {
        my ($status, $host) = @check;
        my $empty_whitelist_note = ($status == 2 ? ' (which is empty)' : '');
        OpenQA::Utils::log_fatal("asset download: host $host of URL $url is not on the whitelist$empty_whitelist_note");
    }

    if ($do_extract) {
        OpenQA::Utils::log_debug("asset download: downloading $url, uncompressing to $assetpath...");
    }
    else {
        OpenQA::Utils::log_debug("asset download: downloading $url to $assetpath...");
    }

    # start tx allowing >16MiB downloads (http://mojolicio.us/perldoc/Mojolicious/Guides/Cookbook#Large-file-downloads)
    my $ua = Mojo::UserAgent->new(max_redirects => 5);
    my $tx = $ua->build_tx(GET => $url);
    $tx->res->max_message_size(0);
    $tx = $ua->start($tx);

    # check for 4xx/5xx response and connection errors
    if (my $err = $tx->error) {
        # clean possibly created incomplete file
        unlink($assetpath);

        my $msg = $err->{code} ? "$err->{code} response: $err->{message}" : "connection error: $err->{message}";
        OpenQA::Utils::log_fatal("asset download: download of $url to $assetpath failed: $msg");
    }

    try {
        # move the downloaded data directly to the requested asset location unless extraction is enabled
        return $tx->res->content->asset->move_to($assetpath) unless $do_extract;

        # rename the downloaded data to the original file name, in MOJO_TMPDIR
        my $tempfile = catfile($ENV{MOJO_TMPDIR}, Mojo::URL->new($url)->path->parts->[-1]);
        $tx->res->content->asset->move_to($tempfile);

        # extract the temp archive file to the requested asset location
        my $ae = Archive::Extract->new(archive => $tempfile);
        my $ok = $ae->extract(to => $assetpath);

        # remove the temporary file
        unlink($tempfile);

        OpenQA::Utils::log_fatal("asset download: extracting $tempfile to $assetpath failed") unless $ok;
    }
    catch {
        OpenQA::Utils::log_fatal("asset download: error renaming or extracting temporary file to $assetpath: $_");
    };

    # set proper permissions for downloaded asset
    chmod 0644, $assetpath;
}

1;
