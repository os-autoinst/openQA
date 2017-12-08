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
use base 'DBIx::Class::Core';
use strict;

use OpenQA::Schema::Result::Jobs;
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
__PACKAGE__->load_components(qw(Timestamps));
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
    },
    last_use_job_id => {
        data_type      => 'integer',
        is_nullable    => 1,
        is_foreign_key => 1,
    },
    fixed => {
        data_type     => 'boolean',
        default_value => '0',
    });
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint([qw(type name)]);
__PACKAGE__->has_many(jobs_assets => 'OpenQA::Schema::Result::JobsAssets', 'asset_id');
__PACKAGE__->many_to_many(jobs => 'jobs_assets', 'job');
__PACKAGE__->belongs_to(last_use_job => 'OpenQA::Schema::Result::Jobs', 'last_use_job_id');

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

# actually checking the file - will be updated to fixed in DB by limit_assets
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
        use File::Path 'remove_tree';
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
        return;
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
                    OpenQA::Utils::log_error("Extracting $tempfile to $assetpath failed!");
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
            return;
        };
    }
    else {
        # Clean up after ourselves. Probably won't exist, but just in case
        OpenQA::Utils::log_error("Download of $url to $assetpath failed! Deleting files.");
        unlink($assetpath);
        return;
    }
    # set proper permissions for downloaded asset
    chmod 0644, $assetpath;

}

# this is a GRU task - abusing the namespace
sub limit_assets {
    my ($app) = @_;
    my $groups = $app->db->resultset('JobGroups')->search(undef, {order_by => 'id'});
    my $asset_resultset = $app->db->resultset('Assets');

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

    # define variables to keep track of all assets related to jobs
    my %seen_asset;       # group ID by asset ID, just to find assets having no group
    my %toremove;         # assets to be removed when $doremove
    my %keep;             # assets needed to be kept
    my %size_by_group;    # the size of assets which are exclusively kept by a certain group
    my $doremove   = 0;   # whether we actually want to remove something
    my $debug_keep = 0;   # enables debug output

    # these querie are just too much for dbix
    my $dbh = $app->schema->storage->dbh;
    my $job_assets_sth
      = $dbh->prepare(
"select a.*,max(j.id) from jobs_assets ja join jobs j on j.id=ja.job_id join assets a on a.id=ja.asset_id where j.group_id=? group by a.id order by max desc;"
      );

    # prefetch all assets
    my %assets;
    while (my $a = $asset_resultset->next) {
        $assets{$a->id} = $a;
        if ($a->is_fixed) {
            $a->update({fixed => 1});
            $keep{$a->id} = {log_msg => "fixed"};
        }
        else {
            $a->update({fixed => 0});
        }
    }

    # find relevant assets which belong to a job group
    while (my $g = $groups->next) {
        my $group_id  = $g->id;
        my $sizelimit = $g->size_limit_gb * 1024 * 1024 * 1024;
        my $reduceto  = $sizelimit * 0.8;

        # initialize %size_by_group for the current group
        $size_by_group{$group_id} = 0;

        $job_assets_sth->execute($group_id);

        # define variable to keep track of all the jobs which have been kept
        my @kept_by_jobgroup;

        while (my $a = $job_assets_sth->fetchrow_hashref) {
            my $asset = $assets{$a->{id}};

            # ignore fixed assets
            next if $asset->fixed;

            OpenQA::Utils::log_debug(
                sprintf "Group %d: %s/%s %s->%s",
                $group_id, $asset->type, $asset->name,
                human_readable_size($asset->size // 0),
                human_readable_size($sizelimit));

            # add asset to mapping of seen assets by group
            $seen_asset{$asset->id} = $group_id;

            # check whether the asset has a size and whether we haven't exceeded the reduce limit
            my $size = $asset->ensure_size;
            if ($size > 0 && $reduceto > 0) {
                # keep asset

                # determine whether the asset is kept exclusively by this group
                my $asset_id       = $a->{id};
                my $existing_entry = $keep{$asset_id};
                my $is_exclusive   = not defined($existing_entry)
                  || ($existing_entry->{exclusive} && $existing_entry->{group_id} == $group_id);

                # add entry for kept asset
                my $kept_asset = $keep{$asset_id} = {
                    group_id  => $group_id,
                    job_id    => $a->{max},
                    log_msg   => sprintf("%s: %s/%s", $g->name, $asset->type, $asset->name),
                    size      => $size,
                    exclusive => $is_exclusive,
                };
                # NOTE: this might override the group/job information about the kept asset
                # in case the asset is kept because of multiple jobs

                # add asset to list by assets kept by the current job group (used for debugging purposes only)
                push(@kept_by_jobgroup, $kept_asset) if $debug_keep;
            }
            else {
                # add assets to removal list
                $toremove{$asset->id} = sprintf "%s/%s", $asset->type, $asset->name;
                # set flag for removal if we have exceeded the actual size limit
                $doremove = 1 if ($sizelimit <= 0);
            }

            $sizelimit -= $size;
            $reduceto  -= $size;
        }

        # print messages
        if ($debug_keep && @kept_by_jobgroup) {
            OpenQA::Utils::log_debug('the following assets are kept by job group: ' . $g->name);
            for my $kept_asset (@kept_by_jobgroup) {
                OpenQA::Utils::log_debug($kept_asset->{log_msg} . '; referencing job: ' . $kept_asset->{job_id});
            }
        }
    }

    # use DBD::Pg as dbix doesn't seem to have a direct update call - find()->update are 2 queries
    my $update_sth = $dbh->prepare('UPDATE assets SET last_use_job_id = ? WHERE id = ?');

    # remove all kept assets from the removal list and propagate last update to asset table
    # and accumulate size of exclusively kept assets per job group
    for my $id (sort keys %keep) {
        my $asset = $keep{$id};

        OpenQA::Utils::log_debug("KEEP $asset->{log_msg}") if $debug_keep;
        delete $toremove{$id};

        # set the time of the last use and the related job group
        $update_sth->execute($asset->{job_id}, $id);

        $size_by_group{$asset->{group_id}} += $asset->{size} if $asset->{exclusive};
    }

    # remove assets in removal list (from db and disk)
    if ($doremove) {
        # skip assets for pending jobs
        my $pending = $app->db->resultset('Jobs')->search({state => [OpenQA::Schema::Result::Jobs::PENDING_STATES]})
          ->get_column('id')->as_query;
        my @pendassets
          = $app->db->resultset('JobsAssets')->search({job_id => {-in => $pending}})->get_column('asset_id')->all;
        my $removes = $app->db->resultset('Assets')->search(
            {
                -and => [
                    id => {in        => [sort keys %toremove]},
                    id => {'-not in' => \@pendassets},
                ],
            },
            {
                order_by => qw(t_created)
            });
        while (my $a = $removes->next) {
            $a->remove_from_disk;
            $a->delete;
        }
    }

    # update accumulated sizes in the data base
    $update_sth = $dbh->prepare('UPDATE job_groups SET exclusively_kept_asset_size = ? WHERE id = ?');
    for my $group_id (keys %size_by_group) {
        $update_sth->execute($size_by_group{$group_id}, $group_id);
    }

    # find assets which do not belong to a job group
    my $timecond = {"<" => time2str('%Y-%m-%d %H:%M:%S', time - 24 * 3600, 'UTC')};
    my $search = {t_created => $timecond, type => [qw(iso hdd repo)], id => {-not_in => [sort keys %seen_asset]}};
    my $assets = $app->db->resultset('Assets')->search($search, {order_by => [qw(t_created)]});

    # remove all assets older than 14 days which do not belong to a job group
    while (my $a = $assets->next) {
        next if $a->fixed;
        my $delta = $a->t_created->delta_days(DateTime->now)->in_units('days');
        if ($delta >= 14 || $a->ensure_size == 0) {
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

    # search for new assets and register them
    for my $type (qw(iso repo hdd)) {
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
                    OpenQA::Utils::log_info "Registering asset $type/$asset";
                    $app->db->resultset('Assets')->register($type, $asset);
                }
            }
        }
    }
}

1;
