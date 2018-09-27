# Copyright (C) 2014-2018 SUSE LLC
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

package OpenQA::Schema::ResultSet::Assets;
use strict;
use base 'DBIx::Class::ResultSet';
use OpenQA::Utils qw(log_warning locate_asset human_readable_size log_debug);
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use File::Basename;

# called when uploading an asset or finding one in scanning
sub register {
    my ($self, $type, $name, $missingok) = @_;
    $missingok //= 0;

    our %types = map { $_ => 1 } qw(iso repo hdd other);
    unless ($types{$type}) {
        log_warning "asset type '$type' invalid";
        return;
    }
    unless (locate_asset $type, $name, mustexist => 1) {
        if (!$missingok) {
            log_warning "no file found for asset '$name' type '$type'";
        }
        return;
    }

    return $self->result_source->schema->txn_do(
        sub {
            return $self->find_or_create(
                {
                    type => $type,
                    name => $name,
                },
                {
                    key => 'assets_type_name',
                });
        });
}

sub scan_for_untracked_assets {
    my ($self) = @_;

    # search for new assets and register them
    for my $type (qw(iso repo hdd)) {
        my $dh;
        next unless opendir($dh, $OpenQA::Utils::assetdir . "/$type");
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
        my %paths;
        for my $path (@paths) {

            my $basepath = basename($path);
            # very specific to our external syncing
            next if $basepath =~ m/CURRENT/;
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
            $paths{$basepath} = 0;
        }
        my $assets = $self->search({type => $type});
        while (my $as = $assets->next) {
            $paths{$as->name} = $as->id;
        }
        for my $asset (keys %paths) {
            if ($paths{$asset} == 0) {
                OpenQA::Utils::log_info "Registering asset $type/$asset";
                $self->register($type, $asset);
            }
        }
    }
}

# refreshes 'fixed' and 'size' of all assets
sub refresh_assets {
    my ($self) = @_;

    while (my $asset = $self->next) {
        if ($asset->is_fixed) {
            $asset->update({fixed => 1});
        }
        else {
            $asset->update({fixed => 0});
        }

        $asset->refresh_size;
    }
}

sub status {
    my ($self, %options) = @_;
    my $rsource = $self->result_source;
    my $schema  = $rsource->schema;
    my $dbh     = $schema->storage->dbh;

    # define query for prefetching the assets - note the sort order here:
    # We sort the assets in descending order by highest related job ID,
    # so assets for recent jobs are considered first (and most likely to be kept).
    # Use of coalesce is required; otherwise assets without any job would end up
    # at the top.
    my $prioritized_assets_query;
    if ($options{compute_pending_state_and_max_job}) {
        $prioritized_assets_query = <<'END_SQL';
            select
                a.id as id, a.name as name, a.t_created as t_created, a.size as size, a.type as type,
                a.fixed as fixed,
                coalesce(max(j.id), -1) as max_job,
                max(case when j.id is not null and j.result='none' then 1 else 0 end) as pending
            from assets a
                left join jobs_assets ja on a.id=ja.asset_id
                left join jobs j on j.id=ja.job_id
            group by a.id
            order by max_job desc, a.t_created desc;
END_SQL
    }
    else {
        $prioritized_assets_query = <<'END_SQL';
            select
                id, name, t_created, size, type, fixed,
                coalesce(last_use_job_id, -1) as max_job
            from assets
            order by max_job desc, t_created desc;
END_SQL
    }

    # prefetch all assets
    my %asset_info;
    my @assets;
    my $assets_arrayref = $dbh->selectall_arrayref($prioritized_assets_query);
    for my $asset_array (@$assets_arrayref) {
        my $id      = $asset_array->[0];
        my $type    = $asset_array->[4];
        my $fixed   = $asset_array->[5];
        my $dirname = ($fixed ? $type . '/fixed/' : $type . '/');
        my $max_job = $asset_array->[6];
        my %asset   = (
            id        => $id,
            name      => ($dirname . $asset_array->[1]),
            t_created => $asset_array->[2],
            size      => $asset_array->[3],
            type      => $type,
            fixed     => $fixed,
            max_job   => ($max_job >= 0 ? $max_job : undef),
            pending   => $asset_array->[7],
            groups    => {},
        );
        $asset_info{$id} = \%asset;
        push(@assets, \%asset);
    }

    # define a query to find the latest job for each asset by group
    my $max_job_by_group_query;
    if ($options{compute_max_job_by_group}) {
        $max_job_by_group_query = <<'END_SQL';
         select a.id as asset_id, max(j.id) as max_job
            from jobs_assets ja
              join jobs j on j.id=ja.job_id
              join assets a on a.id=ja.asset_id
              where group_id = ?
           group by a.id;
END_SQL
    }
    else {
        $max_job_by_group_query = <<'END_SQL';
         select a.id as asset_id
            from jobs_assets ja
              join jobs j on j.id=ja.job_id
              join assets a on a.id=ja.asset_id
              where group_id = ?
           group by a.id;
END_SQL
    }
    my $max_job_by_group_prepared_query = $dbh->prepare($max_job_by_group_query);

    # query list of job groups to show assets by job group
    # We collect data required for /admin/assets *and* the limit_assets task
    my $groups = $schema->resultset('JobGroups');
    my %group_infos;
    $group_infos{0} = {
        size_limit_gb => 0,
        size          => 0,
        group         => 'Untracked',
        id            => undef,
        picked        => 0,
    };

    # find relevant assets which belong to a job group
    while (my $group = $groups->next) {
        my $group_id      = $group->id;
        my $size_limit_gb = $group->size_limit_gb;
        $group_infos{$group_id} = {
            id            => $group_id,
            size_limit_gb => $size_limit_gb,
            size          => $size_limit_gb * 1024 * 1024 * 1024,
            picked        => 0,
            group         => $group->full_name,
        };

        # add the max job ID for this group to
        $max_job_by_group_prepared_query->execute($group_id);
        while (my $result = $max_job_by_group_prepared_query->fetchrow_hashref) {
            my $asset_info = $asset_info{$result->{asset_id}} or next;
            $asset_info->{groups}->{$group_id} = $result->{max_job};
        }
    }

    # compute group sizes
    for my $asset (@assets) {
        my $largest_group = 0;
        my $largest_size  = 0;
        my @groups        = sort { $a <=> $b } keys %{$asset->{groups}};
        my $size          = $asset->{size} // 0;
        for my $g (@groups) {
            log_debug("Asset $asset->{type}/$asset->{name} ($size) fits into $g: $group_infos{$g}->{size}?");
            if ($largest_size < $group_infos{$g}->{size} && $group_infos{$g}->{size} >= $size) {
                $largest_size  = $group_infos{$g}->{size};
                $largest_group = $g;
                log_debug("Asset $asset->{name} ($size) picked into $g");
            }
        }
        $asset->{picked_into} = $largest_group;
        $group_infos{$largest_group}->{size} -= $size;
        $group_infos{$largest_group}->{picked} += $size;
    }

    return {assets => \@assets, groups => \%group_infos};
}

1;
