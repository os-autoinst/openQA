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
      unless my $guard = $app->minion->guard("limit_asset_download_${assetpath}_task", 3600);

    my $ipc = OpenQA::IPC->ipc;

    # Bail if the dest file exists (in case multiple downloads of same ISO
    # are scheduled)
    return if (-e $assetpath);
    my $assetdir = (splitpath($assetpath))[1];

    OpenQA::Utils::log_fatal("download_asset: cannot write to $assetdir") unless (-w $assetdir);

    # check URL is whitelisted for download. this should never fail;
    # if it does, it means this task has been created without going
    # through the ISO API controller, and that means either a code
    # change we didn't think through or someone being evil
    my @check = OpenQA::Utils::check_download_url($url, $app->config->{global}->{download_domains});
    if (@check) {
        my ($status, $host) = @check;
        if ($status == 2) {
            OpenQA::Utils::log_fatal("download_asset: no hosts are whitelisted for asset download!");
        }
        else {
            OpenQA::Utils::log_fatal("download_asset: URL $url host $host is blacklisted!");
        }
        OpenQA::Utils::log_fatal("**API MAY HAVE BEEN BYPASSED TO CREATE THIS TASK!**");
    }
    if ($do_extract) {
        OpenQA::Utils::log_debug("Downloading $url, uncompressing to $assetpath...");
    }
    else {
        OpenQA::Utils::log_debug("Downloading $url to $assetpath...");
    }
    my $ua = Mojo::UserAgent->new(max_redirects => 5);
    my $tx = $ua->build_tx(GET => $url);

    # Allow >16MiB downloads
    # http://mojolicio.us/perldoc/Mojolicious/Guides/Cookbook#Large-file-downloads
    $tx->res->max_message_size(0);
    $tx = $ua->start($tx);
    if (!$tx->error) {
        try {
            if ($do_extract) {

                # Rename the downloaded data to the original file name, in
                # MOJO_TMPDIR
                my $tempfile = catfile($ENV{MOJO_TMPDIR}, Mojo::URL->new($url)->path->parts->[-1]);
                $tx->res->content->asset->move_to($tempfile);

                # Extract the temp archive file to the requested asset location
                my $ae = Archive::Extract->new(archive => $tempfile);
                my $ok = $ae->extract(to => $assetpath);

                # Remove the temporary file
                unlink($tempfile);

                OpenQA::Utils::log_fatal("Extracting $tempfile to $assetpath failed!") unless $ok;
            }
            else {
                # Just directly move the downloaded data to the requested
                # asset location
                $tx->res->content->asset->move_to($assetpath);
            }
        }
        catch {
            OpenQA::Utils::log_fatal("Error renaming or extracting temporary file to $assetpath: $_");
        };
    }
    else {
        # Clean up after ourselves. Probably won't exist, but just in case
        unlink($assetpath);
        OpenQA::Utils::log_fatal("Download of $url to $assetpath failed! Deleting files.");
    }

    # set proper permissions for downloaded asset
    chmod 0644, $assetpath;
}

1;
