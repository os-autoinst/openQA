# Copyright 2018-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::Asset::Download;
use Mojo::Base 'Mojolicious::Plugin';

use OpenQA::Utils qw(check_download_url);
use OpenQA::Downloader;
use Mojo::File 'path';

sub register {
    my ($self, $app) = @_;
    $app->minion->add_task(download_asset => \&_download);
}

sub _create_symlinks {
    my ($job, $ctx, $assetpath, $other_destinations) = @_;

    my @error_message;
    for my $link_path (@$other_destinations) {
        $ctx->debug(qq{Creating symlink "$link_path" to "$assetpath"});
        symlink($assetpath, $link_path) || push @error_message,
          "Cannot create symlink from $assetpath to $link_path: $!";
    }
    if (scalar(@error_message) > 0) {
        $ctx->error(my $msg = join("\n", @error_message));
        return $job->fail($msg);
    }
}

sub _download {
    my ($job, $url, $assetpaths, $do_extract) = @_;

    my $app = $job->app;
    my $job_id = $job->id;

    # deal with one download task has many destinations
    my $assetpath = $assetpaths;
    my @other_destinations;
    if (ref($assetpaths) eq 'ARRAY') {
        @other_destinations = @$assetpaths;
        $assetpath = shift @other_destinations;
    }
    else {
        $assetpaths = [$assetpaths];
    }

    # Prevent multiple asset download tasks for the same asset to run in parallel
    return $job->retry({delay => 30})
      unless my $guard = $app->minion->guard("limit_asset_download_${assetpath}_task", 7200);

    my $log = $app->log;
    my $ctx = $log->context("[#$job_id]");

    # skip download if the one dest file exists (in case multiple downloads of same ISO are scheduled)
    my @existing_dest_files;
    my @missing_dest_files;
    -e $_ ? push @existing_dest_files, $_ : push @missing_dest_files, $_ for @$assetpaths;
    if (@existing_dest_files) {
        $ctx->info(my $msg = qq{Skipping download of "$url" because file "$existing_dest_files[0]" already exists});
        _create_symlinks($job, $ctx, $existing_dest_files[0], \@missing_dest_files) if @missing_dest_files;
        return undef;
    }

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

    if ($do_extract) { $ctx->debug(qq{Downloading and uncompressing "$url" to "$assetpath"}) }
    else { $ctx->debug(qq{Downloading "$url" to "$assetpath"}) }

    my $downloader = OpenQA::Downloader->new(log => $ctx, tmpdir => $ENV{MOJO_TMPDIR});
    my $options = {
        extract => $do_extract,
        on_success => sub {
            chmod 0644, $assetpath;
            $ctx->debug(qq{Download of "$assetpath" successful});
        }
    };
    return _create_symlinks($job, $ctx, $assetpath, \@other_destinations)
      unless my $err = $downloader->download($url, $assetpath, $options);
    my $res = $downloader->res;
    $ctx->error(my $msg = qq{Downloading "$url" failed with: $err});
    return $res && $res->is_client_error ? $job->finish($msg) : $job->fail($msg);
}

1;
