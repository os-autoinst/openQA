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

use OpenQA::Utils qw(check_download_url);
use OpenQA::Downloader;
use Mojo::File 'path';

sub register {
    my ($self, $app) = @_;
    $app->minion->add_task(download_asset => \&_download);
}

sub _download {
    my ($job, $url, $assetpath, $do_extract) = @_;

    my $app    = $job->app;
    my $job_id = $job->id;

    # Prevent multiple asset download tasks for the same asset to run in parallel
    return $job->retry({delay => 30})
      unless my $guard = $app->minion->guard("limit_asset_download_${assetpath}_task", 7200);

    my $log = $app->log;
    my $ctx = $log->context("[#$job_id]");

    # bail if the dest file exists (in case multiple downloads of same ISO are scheduled)
    return undef if -e $assetpath;
    my $assetdir = path($assetpath)->dirname->to_string;
    unless (-w $assetdir) {
        $ctx->error(my $msg = "asset download: cannot write to $assetdir");
        die $msg;
    }

    # check whether URL is whitelisted for download. this should never fail;
    # if it does, it means this task has been created without going
    # through the ISO API controller, and that means either a code
    # change we didn't think through or someone being evil
    if (my @check = check_download_url($url, $app->config->{global}->{download_domains})) {
        my ($status, $host) = @check;
        my $empty_whitelist_note = ($status == 2 ? ' (which is empty)' : '');
        $ctx->error(my $msg = "asset download: host $host of URL $url is not on the whitelist$empty_whitelist_note");
        die $msg;
    }

    if   ($do_extract) { $ctx->debug("asset download: downloading $url, uncompressing to $assetpath...") }
    else               { $ctx->debug("asset download: downloading $url to $assetpath...") }

    my $downloader = OpenQA::Downloader->new(log => $ctx, tmpdir => $ENV{MOJO_TMPDIR});
    my $options    = {
        extract    => $do_extract,
        on_success => sub { chmod 0644, $assetpath }
    };
    $downloader->download($url, $assetpath, $options);
}

1;
