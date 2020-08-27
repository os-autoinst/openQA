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
    my ($job, $url, $assetpaths, $do_extract) = @_;

    my $app    = $job->app;
    my $job_id = $job->id;

    # deal with one download task has many destinations
    my $assetpath          = $assetpaths;
    my $other_destinations = [];
    if (ref($assetpaths) eq 'ARRAY') {
        $assetpath          = shift @$assetpaths;
        $other_destinations = $assetpaths;
    }

    # Prevent multiple asset download tasks for the same asset to run in parallel
    return $job->retry({delay => 30})
      unless my $guard = $app->minion->guard("limit_asset_download_${assetpath}_task", 7200);

    my $log = $app->log;
    my $ctx = $log->context("[#$job_id]");

    # bail if the dest file exists (in case multiple downloads of same ISO are scheduled)
    return $ctx->info(my $msg = qq{Skipping download of "$url" to "$assetpath" because file already exists})
      if -e $assetpath;

    unless (-w (my $assetdir = path($assetpath)->dirname)) {
        $ctx->error(my $msg = qq{Cannot write to asset directory "$assetdir"});
        return $job->fail($msg);
    }

    # check whether URL is passlisted for download. this should never fail;
    # if it does, it means this task has been created without going
    # through the ISO API controller, and that means either a code
    # change we didn't think through or someone being evil
    if (my ($status, $host) = check_download_url($url, $app->config->{global}->{download_domains})) {
        my $empty_passlist_note = ($status == 2 ? ' (which is empty)' : '');
        $ctx->error(my $msg = qq{Host "$host" of URL "$url" is not on the passlist$empty_passlist_note});
        return $job->fail($msg);
    }

    if   ($do_extract) { $ctx->debug(qq{Downloading and uncompressing "$url" to "$assetpath"}) }
    else               { $ctx->debug(qq{Downloading "$url" to "$assetpath"}) }

    my $downloader = OpenQA::Downloader->new(log => $ctx, tmpdir => $ENV{MOJO_TMPDIR});
    my $options    = {
        extract    => $do_extract,
        on_success => sub {
            chmod 0644, $assetpath;
            $ctx->debug(qq{Download of "$assetpath" successful});
        }
    };
    unless ($downloader->download($url, $assetpath, $options)) {
        $ctx->error(my $msg = qq{Downloading "$url" failed because of too many download errors});
        return $job->fail($msg);
    }

    my @error_message;
    symlink($assetpath, $_) || push @error_message, "Cannot create symlink from $assetpath to $_ : $!"
      for (@$other_destinations);
    if (scalar(@error_message) > 0) {
        $ctx->error(my $msg = join('\n', @error_message));
        return $job->fail($msg);
    }
}

1;
