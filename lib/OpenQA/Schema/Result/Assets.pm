# Copyright 2014-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::Assets;

use strict;
use warnings;

use base 'DBIx::Class::Core';

use OpenQA::App;
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use OpenQA::Log qw(log_info log_error);
use OpenQA::Utils;
use Date::Format;
use Archive::Extract;
use File::Basename;
use File::Spec::Functions qw(catfile splitpath);
use File::Path 'remove_tree';
use Mojo::UserAgent;
use Mojo::URL;
use Try::Tiny;

__PACKAGE__->table('assets');
__PACKAGE__->load_components(qw(Timestamps));
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    type => {
        data_type => 'text',
    },
    name => {
        data_type => 'text',
    },
    size => {    # initialized when registering assets from job settings, refreshed when scanning assets
        data_type => 'bigint',
        is_nullable => 1    # is null for assets which do not exist
    },
    checksum => {
        data_type => 'text',
        is_nullable => 1,
        default_value => undef
    },
    last_use_job_id => {
        data_type => 'integer',
        is_nullable => 1,
        is_foreign_key => 1,
    },
    fixed => {
        data_type => 'boolean',
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
    return $self->{_location} //= locate_asset($self->type, $self->name);
}

# actually checking the file - will be updated to fixed in DB by limit_assets
# (and NOT when rendering the admin assets table)
sub is_fixed {
    my ($self) = @_;
    return (index($self->disk_file, catfile('fixed', $self->name)) > -1);
}

sub remove_from_disk {
    my ($self) = @_;

    my $type = $self->type;
    my $name = $self->name;
    my $file = locate_asset($type, $name, mustexist => 1);
    if (!defined $file) {
        log_info("GRU: skipping removal of $type/$name; it does not exist anyways");
        return undef;
    }
    if (-f $file ? unlink($file) : remove_tree($file)) {
        log_info("GRU: removed $file");
    }
    else {
        log_error("GRU: unable to remove $file");    # uncoverable statement trivial error report
    }
}

# override to automatically remove the corresponding file from disk when deleting the database entry
sub delete {
    my ($self) = @_;

    $self->remove_from_disk;
    return $self->SUPER::delete;
}

sub ensure_size {
    my ($self) = @_;
    my $size = $self->size;
    return $size if defined $size;
    return $self->refresh_size($size);
}

sub refresh_size {
    my ($self, $current_size) = @_;
    $current_size //= $self->size;

    my $new_size = undef;
    my @stat = stat(my $disk_file = $self->disk_file);
    if (@stat) {
        if ($self->type eq 'repo') {
            return $current_size if defined($current_size);
            $new_size = _getDirSize($disk_file);
        }
        else {
            $new_size = $stat[7];
        }
    }
    $self->update({size => $new_size})
      if (!defined $new_size ^ !defined $current_size) || ($current_size // 0) != ($new_size // 0);
    return $new_size;
}

# returns whether the specified asset type is considered hidden so it will not be linked by the
# web UI; configured via 'hide_asset_types' setting
sub is_type_hidden {
    my ($type) = @_;
    return grep { $_ eq $type } split(/ /, OpenQA::App->singleton->config->{global}->{hide_asset_types});
}

sub hidden {
    my ($self) = @_;
    return is_type_hidden($self->type);
}

1;
