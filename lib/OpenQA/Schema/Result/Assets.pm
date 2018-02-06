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
__PACKAGE__->has_many(
    jobs_assets => 'OpenQA::Schema::Result::JobsAssets',
    'asset_id'
);
__PACKAGE__->many_to_many(jobs => 'jobs_assets', 'job');
__PACKAGE__->belongs_to(
    last_use_job => 'OpenQA::Schema::Result::Jobs',
    'last_use_job_id',
    {join_type => 'left', on_delete => 'SET NULL'});

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

# override to automatically remove the corresponding file from disk when deleteing the database entry
sub delete {
    my ($self) = @_;

    $self->remove_from_disk;
    return $self->SUPER::delete;
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
            return $self->size
              if defined($self->size) && $size == $self->size;
        }
    }
    $self->update({size => $size});
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

sub _remove_if {
    my ($db, $asset) = @_;
    return if $asset->{fixed} || $asset->{pending};
    $db->resultset('Assets')->single({id => $asset->{id}})->delete;
}

# this is a GRU task - abusing the namespace
sub limit_assets {
    my ($app) = @_;

    my $asset_status = $app->db->resultset('Assets')->status();
    my $assets       = $asset_status->{assets};

    # first remove grouped assets
    for my $asset (@$assets) {
        if (keys %{$asset->{groups}} && !$asset->{picked_into}) {
            _remove_if($app->db, $asset);
        }
    }

    # use DBD::Pg as dbix doesn't seem to have a direct update call - find()->update are 2 queries
    my $dbh        = $app->schema->storage->dbh;
    my $update_sth = $dbh->prepare('UPDATE assets SET last_use_job_id = ? WHERE id = ?');

    # remove all assets older than 14 days which do not belong to a job group
    for my $asset (@$assets) {
        $update_sth->execute($asset->{max_job} ? $asset->{max_job} : undef, $asset->{id});

        next if $asset->{fixed} || scalar(keys %{$asset->{groups}}) > 0;

        # age is in minutes
        my $delta = int($asset->{age} / 60 / 24);
        if ($delta >= 14 || $asset->{size} == 0) {
            _remove_if($app->db, $asset);
        }
        else {
            OpenQA::Utils::log_warning(
                "Asset " . $asset->{name} . " is not in any job group, will delete in " . (14 - $delta) . " days");
        }
    }

    # store the exclusively_kept_asset_size in the DB - for the job group edit field
    $update_sth = $dbh->prepare('UPDATE job_groups SET exclusively_kept_asset_size = ? WHERE id = ?');

    for my $group (values %{$asset_status->{groups}}) {
        $update_sth->execute($group->{picked}, $group->{id});
    }

}

1;
