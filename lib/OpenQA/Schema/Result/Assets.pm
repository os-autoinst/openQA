# Copyright (C) 2014-2016 SUSE LLC
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

package OpenQA::Schema::Result::Assets;
use base qw/DBIx::Class::Core/;
use strict;

use OpenQA::Utils;
use OpenQA::IPC;
use Date::Format;
use Archive::Extract;
use File::Basename;
use File::Spec::Functions qw(catfile splitpath);
use Mojo::UserAgent;
use Mojo::URL;
use Try::Tiny;

use db_helpers;

__PACKAGE__->table('assets');
__PACKAGE__->load_components(qw/Timestamps/);
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    type => {
        data_type => 'text',
    },
    name => {
        data_type => 'text',
    },
    size => {
        data_type   => 'bigint',
        is_nullable => 1
    },
    checksum => {
        data_type     => 'text',
        is_nullable   => 1,
        default_value => undef
    });
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint([qw/type name/]);
__PACKAGE__->has_many(jobs_assets => 'OpenQA::Schema::Result::JobsAssets', 'asset_id');
__PACKAGE__->many_to_many(jobs => 'jobs_assets', 'job');

sub _getDirSize {
    my ($dir, $size) = @_;
    $size //= 0;

    opendir(my $dh, $dir) || return 0;
    for my $dirContent (grep(!/^\.\.?/, readdir($dh))) {

        $dirContent = "$dir/$dirContent";

        if (-f $dirContent) {
            my $fsize = -s $dirContent;
            $size += $fsize;
        }
        elsif (-d $dirContent) {
            $size = _getDirSize($dirContent, $size);
        }
    }
    closedir($dh);
    return $size;
}

sub disk_file {
    my ($self) = @_;
    return locate_asset($self->type, $self->name);
}

sub is_fixed {
    my ($self) = @_;
    return (index($self->disk_file, catfile('fixed', $self->name)) > -1);
}

sub remove_from_disk {
    my ($self) = @_;

    my $file = $self->disk_file;
    OpenQA::Utils::log_info("GRU: removing $file");
    if ($self->type eq 'iso' || $self->type eq 'hdd') {
        return unless -f $file;
        unlink($file) || die "can't remove $file";
    }
    elsif ($self->type eq 'repo') {
        use File::Path qw(remove_tree);
        remove_tree($file) || print "can't remove $file\n";
    }

}

sub ensure_size {
    my ($self) = @_;

    my $size = 0;
    my @st   = stat($self->disk_file);
    if (@st) {
        if ($self->type eq 'repo') {
            return $self->size if defined($self->size);
            $size = _getDirSize($self->disk_file);
        }
        else {
            $size = $st[7];
            return $self->size if defined($self->size) && $size == $self->size;
        }
    }
    $self->update({size => $size}) if $size;
    return $size;
}

sub hidden {
    # 1 if asset should not be linked from the web UI (as set by
    # 'hide_asset_types' config setting), otherwise 0
    my ($self) = @_;
    my @types = split(/ /, $OpenQA::Utils::app->config->{global}->{hide_asset_types});
    return grep { $_ eq $self->type } @types;
}

# A GRU task...arguments are the URL to grab and the full path to save
# it in. scheduled in ISO controller
sub download_asset {
    my ($app, $args) = @_;
    my ($url, $assetpath, $do_extract) = @{$args};
    my $ipc = OpenQA::IPC->ipc;
    # Bail if the dest file exists (in case multiple downloads of same ISO
    # are scheduled)
    return if (-e $assetpath);

    my $assetdir = (splitpath($assetpath))[1];
    unless (-w $assetdir) {
        OpenQA::Utils::log_error("download_asset: cannot write to $assetdir");
        # we're not going to die because this is a gru task and we don't
        # want to cause the Endless Gru Loop Of Despair, just return and
        # let the jobs fail
        notify_workers;
        return;
    }

    # check URL is whitelisted for download. this should never fail;
    # if it does, it means this task has been created without going
    # through the ISO API controller, and that means either a code
    # change we didn't think through or someone being evil
    my @check = check_download_url($url, $app->config->{global}->{download_domains});
    if (@check) {
        my ($status, $host) = @check;
        if ($status == 2) {
            OpenQA::Utils::log_error("download_asset: no hosts are whitelisted for asset download!");
        }
        else {
            OpenQA::Utils::log_error("download_asset: URL $url host $host is blacklisted!");
        }
        OpenQA::Utils::log_error("**API MAY HAVE BEEN BYPASSED TO CREATE THIS TASK!**");
        notify_workers;
        return;
    }
    if ($do_extract) {
        OpenQA::Utils::log_debug("Downloading " . $url . ", uncompressing to " . $assetpath . "...");
    }
    else {
        OpenQA::Utils::log_debug("Downloading " . $url . " to " . $assetpath . "...");
    }
    my $ua = Mojo::UserAgent->new(max_redirects => 5);
    my $tx = $ua->build_tx(GET => $url);
    # Allow >16MiB downloads
    # http://mojolicio.us/perldoc/Mojolicious/Guides/Cookbook#Large-file-downloads
    $tx->res->max_message_size(0);
    $tx = $ua->start($tx);
    if ($tx->success) {
        try {
            if ($do_extract) {
                # Rename the downloaded data to the original file name, in
                # MOJO_TMPDIR
                my $tempfile = catfile($ENV{MOJO_TMPDIR}, Mojo::URL->new($url)->path->parts->[-1]);
                $tx->res->content->asset->move_to($tempfile);

                # Extract the temp archive file to the requested asset location
                my $ae = Archive::Extract->new(archive => $tempfile);
                my $ok = $ae->extract(to => $assetpath);
                if (!$ok) {
                    OpenQA::Utils::log_error("Extracting failed!");
                }

                # Remove the temporary file
                unlink($tempfile);
            }
            else {
                # Just directly move the downloaded data to the requested
                # asset location
                $tx->res->content->asset->move_to($assetpath);
            }
        }
        catch {
            # again, we're trying not to die here, but log and return on fail
            OpenQA::Utils::log_error("Error renaming or extracting temporary file to $assetpath: $_");
            notify_workers;
            return;
        };
    }
    else {
        # Clean up after ourselves. Probably won't exist, but just in case
        OpenQA::Utils::log_error("Downloading failed! Deleting files");
        unlink($assetpath);
        notify_workers;
        return;
    }

    # We want to notify workers either way: if we failed to download, we
    # want the jobs to run and fail.
    notify_workers;
}

# this is a GRU task - abusing the namespace
sub limit_assets {
    my ($app) = @_;
    my $groups = $app->db->resultset('JobGroups');
    # keep track of all assets related to jobs
    my %seen_asset;
    my %toremove;
    my %keep;
    my $doremove = 0;

    my $debug_keep = 0;

    # to avoid perpetually being on the very edge of the size limit and prone
    # to edge cases while multiple jobs that may upload images are running,
    # we take a number 80% of the size limit. we go through the group and keep
    # all assets that fit within that number in %keep and the others in
    # toremove. Once we exceed the actual size limit, we set doremove to 1 to
    # indicate that removal should occur (so we don't do any removal if total
    # size is between reduceto and sizelimit).
    # If $doremove is 1 we remove all in %toremove that no other group put in
    # %keep (assets can easily be in 2 groups - and both have different update
    # ratios, it's up to the admin to configure the size limit)
    while (my $g = $groups->next) {
        my $sizelimit = $g->size_limit_gb * 1024 * 1024 * 1024;
        my $reduceto  = $sizelimit * 0.8;
        # we need to find a distinct set of assets per job group ordered by
        # their last use. Need to do this in 2 steps
        my @job_assets = $app->db->resultset('JobsAssets')->search(
            {
                job_id => {-in => $g->jobs->get_column('id')->as_query},
            },
            {
                select   => ['asset_id', 'created_by', {max => 'job_id', -as => 'latest'},],
                group_by => 'asset_id,created_by',
                order_by => {-desc => 'latest'}})->all;
        my %assets;
        my $assets = $app->db->resultset('Assets')->search(
            {
                id => {-in => [map { $_->asset_id } @job_assets]}});
        while (my $a = $assets->next) {
            $assets{$a->id} = $a;
        }
        for my $a (@job_assets) {
            my $asset = $assets{$a->asset_id};
            OpenQA::Utils::log_debug(
                sprintf "Group %s: %s/%s %s->%s",
                $g->name, $asset->type, $asset->name,
                human_readable_size($asset->size // 0),
                human_readable_size($sizelimit));
            # ignore fixed assets
            next if ($asset->is_fixed);
            $seen_asset{$asset->id} = $g->id;
            my $size = $asset->ensure_size;
            if ($size > 0 && $reduceto > 0) {
                $keep{$a->asset_id} = sprintf "%s: %s/%s", $g->name, $asset->type, $asset->name;
            }
            else {
                $toremove{$a->asset_id} = sprintf "%s/%s", $asset->type, $asset->name;
                $doremove = 1 if ($sizelimit <= 0);
            }
            $sizelimit -= $size;
            $reduceto  -= $size;
        }
    }
    for my $id (keys %keep) {
        OpenQA::Utils::log_debug("KEEP $toremove{$id} $keep{$id}") if $debug_keep;
        delete $toremove{$id};
    }
    if ($doremove) {
        my $removes
          = $app->db->resultset('Assets')->search({id => {in => [sort keys %toremove]}}, {order_by => qw/t_created/});
        while (my $a = $removes->next) {
            $a->remove_from_disk;
            $a->delete;
        }
    }
    my $timecond = {"<" => time2str('%Y-%m-%d %H:%M:%S', time - 24 * 3600, 'UTC')};

    my $search = {t_created => $timecond, type => [qw(iso hdd repo)], id => {-not_in => [sort keys %seen_asset]}};
    my $assets = $app->db->resultset('Assets')->search($search, {order_by => [qw(t_created)]});
    while (my $a = $assets->next) {
        next if is_fixed($a);
        my $delta = $a->t_created->delta_days(DateTime->now)->in_units('days');
        if ($delta >= 14) {
            $a->remove_from_disk;
            $a->delete;
        }
        else {
            OpenQA::Utils::log_warning("Asset "
                  . $a->type . "/"
                  . $a->name
                  . " is not in any job group, will delete in "
                  . (14 - $delta)
                  . " days");
        }
    }
    for my $type (qw/iso repo hdd/) {
        my $dh;
        if (opendir($dh, $OpenQA::Utils::assetdir . "/$type")) {
            my %assets;
            my @paths;
            while (readdir($dh)) {
                unless ($_ eq 'fixed' or $_ eq '.' or $_ eq '..') {
                    push(@paths, "$OpenQA::Utils::assetdir/$type/$_");
                }
            }
            closedir($dh);
            if (opendir($dh, $OpenQA::Utils::assetdir . "/$type" . "/fixed")) {
                while (readdir($dh)) {
                    unless ($_ eq 'fixed' or $_ eq '.' or $_ eq '..') {
                        push(@paths, "$OpenQA::Utils::assetdir/$type/fixed/$_");
                    }
                }
                closedir($dh);
            }
            for my $path (@paths) {
                # very specific to our external syncing
                next if basename($path) =~ m/CURRENT/;
                next if -l $path;
                # ignore files not owned by us
                next unless -o $path;
                if ($type eq 'repo') {
                    next unless -d $path;
                }
                else {
                    next unless -f $path;
                    if ($type eq 'iso') {
                        next unless $path =~ m/\.iso$/;
                    }
                }
                $assets{basename($path)} = 0;
            }
            $assets = $app->db->resultset('Assets')->search({type => $type, name => {in => [keys %assets]}});
            while (my $a = $assets->next) {
                $assets{$a->name} = $a->id;
            }
            for my $asset (keys %assets) {
                if ($assets{$asset} == 0) {
                    OpenQA::Utils::log_error "Registering asset $type/$asset";
                    $app->db->resultset('Assets')->register($type, $asset);
                }
            }
        }
    }
}

1;
