# Copyright (C) 2014-2021 SUSE LLC
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

package OpenQA::Schema::ResultSet::Assets;

use strict;
use warnings;

use Mojo::Base -strict, -signatures;
use base 'DBIx::Class::ResultSet';

use DBIx::Class::Timestamps 'now';
use OpenQA::Log qw(log_info log_debug log_warning);
use OpenQA::Utils qw(prjdir assetdir locate_asset);
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use Mojo::JSON 'encode_json';
use File::Basename;
use Try::Tiny;

use constant {STATUS_CACHE_FILE => '/webui/cache/asset-status.json'};
use constant TYPES => (qw(iso repo hdd other));

sub status_cache_file {
    return prjdir() . STATUS_CACHE_FILE;
}

# called when uploading an asset or finding one in scanning
sub register ($self, $type, $name, $options = {}) {
    unless ($name)                 { log_warning 'attempt to register asset with empty name'; return undef }
    unless (grep /^$type$/, TYPES) { log_warning "asset type '$type' invalid";                return undef }
    if     (!$options->{missing_ok} && !locate_asset $type, $name, mustexist => 1) {
        log_warning "no file found for asset '$name' type '$type'";
        return undef;
    }
    $self->result_source->schema->txn_do(
        sub {
            my $asset = $self->find_or_create({type => $type, name => $name}, {key => 'assets_type_name'});
            if (my $created_by = $options->{created_by}) {
                my $scope = $options->{scope} // 'public';
                $created_by->jobs_assets->create({asset_id => $asset->id, created_by => 1});
                $created_by->reevaluate_children_asset_settings if $scope ne 'public';
            }
            return $asset;
        });
}

sub scan_for_untracked_assets {
    my ($self) = @_;

    # search for new assets and register them
    for my $type (TYPES) {
        my @paths;

        my $assetdir = assetdir();
        for my $subtype (qw(/ /fixed)) {
            my $path = "$assetdir/$type$subtype";
            my $dh;
            next unless opendir($dh, $path);
            for my $file (readdir($dh)) {
                unless ($file eq 'fixed' or $file eq '.' or $file eq '..') {
                    push(@paths, "$path/$file");
                }
            }
            closedir($dh);
        }

        my %paths;
        for my $path (@paths) {

            my $basepath = basename($path);
            # ignore links
            next if -l $path;

            # ignore files not owned by us
            next unless -o $path;
            # ignore non-existing files and folders
            next unless -e $path;
            $paths{$basepath} = 0;
        }
        my $assets = $self->search({type => $type});
        while (my $as = $assets->next) {
            $paths{$as->name} = $as->id;
        }
        for my $asset (keys %paths) {
            if ($paths{$asset} == 0) {
                log_info "Registering asset $type/$asset";
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
                max(case when j.id is not null and j.state!='done' and j.state!='cancelled' then 1 else 0 end) as pending
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

    # define variables; add "zero group" for groupless assets
    my (@assets, %asset_info, %group_info, %parent_group_info);
    $group_info{0} = {
        size_limit_gb => 0,
        size          => 0,
        group         => 'Untracked',
        id            => undef,
        parent_id     => undef,
        picked        => 0,
    };

    # query the database in one transaction
    $schema->txn_do(
        sub {
            # set transaction-level so "all statements of the current transaction can only see rows committed
            # before the first query [...] statement was executed in this transaction"
            # (quote from https://www.postgresql.org/docs/9.6/sql-set-transaction.html)
            $schema->storage->dbh->prepare('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY DEFERRABLE;')
              ->execute();
            # note: only affects the current transaction (so no reason to reset again)

            # prefetch all assets
            my $assets_arrayref = $dbh->selectall_arrayref($prioritized_assets_query);
            for my $asset_array (@$assets_arrayref) {
                my $id   = $asset_array->[0];
                my $name = $asset_array->[1];
                if (!$name) {
                    log_warning("asset cleanup: Skipping asset $id because its name is empty.");
                    next;
                }

                my $type    = $asset_array->[4];
                my $fixed   = $asset_array->[5];
                my $dirname = ($fixed ? $type . '/fixed/' : $type . '/');
                my $max_job = $asset_array->[6];
                my %asset   = (
                    id        => $id,
                    name      => ($dirname . $name),
                    t_created => $asset_array->[2],
                    size      => $asset_array->[3],
                    type      => $type,
                    fixed     => $fixed,
                    max_job   => ($max_job >= 0 ? $max_job : undef),
                    pending   => $asset_array->[7],
                    groups    => {},
                    parents   => {},
                );
                $asset_info{$id} = \%asset;
                push(@assets, \%asset);
            }

            # query list of job groups to show assets by job group
            # note: We collect data required for /admin/assets *and* the limit_assets task.
            my $groups                      = $schema->resultset('JobGroups');
            my $fail_on_inconsistent_status = $options{fail_on_inconsistent_status};
            while (my $group = $groups->next) {
                my $parent = $group->parent;
                my $parent_id;
                if (defined $parent) {
                    my $parent_size_limit_gb = $parent->size_limit_gb;
                    my $parent_size
                      = (defined $parent_size_limit_gb ? $parent_size_limit_gb * 1024 * 1024 * 1024 : undef);
                    $parent_id = $parent->id;
                    $parent_group_info{$parent_id} = {
                        id            => $parent_id,
                        size_limit_gb => $parent_size_limit_gb,
                        size          => $parent_size,
                        picked        => 0,
                        group         => $parent->name,
                    };
                }

                my $group_id      = $group->id;
                my $size_limit_gb = $group->size_limit_gb;
                $group_info{$group_id} = {
                    id            => $group_id,
                    parent_id     => $parent_id,
                    size_limit_gb => $size_limit_gb,
                    size          => $size_limit_gb * 1024 * 1024 * 1024,
                    picked        => 0,
                    group         => $group->full_name,
                };

                # add the max job ID for this group
                $max_job_by_group_prepared_query->execute($group_id);
                while (my $result = $max_job_by_group_prepared_query->fetchrow_hashref) {
                    my $asset_info   = $asset_info{$result->{asset_id}} or next;
                    my $init_max_job = $asset_info->{max_job} || 0;
                    my $res_max_job  = $result->{max_job};
                    $asset_info->{groups}->{$group_id}   = $res_max_job;
                    $asset_info->{parents}->{$parent_id} = 1 if defined $parent_id;

                    # check whether the data from the 2nd select is inconsistent with what we've got from the 1st
                    # (pure pre-caution, shouldn't happen due to the transaction)
                    die "$asset_info->{name} was scheduled during cleanup"
                      . " (max job initially $init_max_job, now $res_max_job)"
                      if $fail_on_inconsistent_status && $res_max_job && ($res_max_job > $init_max_job);
                }
            }
        });

    # compute group sizes
    for my $asset (@assets) {
        my $largest_group_id  = 0;       # default to "zero group" for groupless assets
        my $largest_parent_id = undef;
        my $largest_size      = 0;
        my @groups            = sort { $a <=> $b } keys %{$asset->{groups}};
        my $asset_name        = $asset->{name};
        my $asset_size        = $asset->{size} // 0;

        # search for parent job group or job group with the highest asset size limit which has still enough space
        # left for the asset
        for my $group_id (@groups) {
            my $group_info        = $group_info{$group_id};
            my $group_size        = $group_info->{size};
            my $parent_group_id   = $group_info->{parent_id};
            my $parent_group_info = defined $parent_group_id   ? $parent_group_info{$parent_group_id} : undef;
            my $parent_group_size = defined $parent_group_info ? $parent_group_info->{size}           : undef;
            if (defined $parent_group_size) {
                log_debug("Checking whether asset $asset_name ($asset_size) fits into"
                      . " parent $parent_group_id ($parent_group_size)");
                next unless $largest_size < $parent_group_size && $parent_group_size >= $asset_size;

                log_debug("Asset $asset_name ($asset_size) picked into parent $parent_group_id");
                $largest_size      = $parent_group_size;
                $largest_parent_id = $parent_group_id;
                $largest_group_id  = $group_id;
            }
            else {
                log_debug("Checking whether asset $asset_name ($asset_size) fits into group $group_id ($group_size)");
                next unless $largest_size < $group_size && $group_size >= $asset_size;

                log_debug("Asset $asset_name ($asset_size) picked into group $group_id");
                $largest_size      = $group_size;
                $largest_parent_id = undef;
                $largest_group_id  = $group_id;
            }
        }

        # account the asset to the determined parent group or job group or the default "zero group" for groupless assets
        my $determined_group;
        $asset->{picked_into} = $largest_group_id;
        if (defined $largest_parent_id) {
            $asset->{picked_into_parent_id} = $largest_parent_id;
            $determined_group = $parent_group_info{$largest_parent_id};
        }
        else {
            $determined_group = $group_info{$largest_group_id};
        }
        $determined_group->{size}   -= $asset_size;
        $determined_group->{picked} += $asset_size;
    }

    # produce cache file for /admin/assets
    unless ($options{skip_cache_file}) {
        my $cache_file_path     = status_cache_file;
        my $new_cache_file_path = "$cache_file_path.new";
        try {
            my $cache_file = Mojo::File->new($new_cache_file_path);
            # ensure parent directory exists
            $cache_file->dirname->make_path();
            # write JSON file, replacing possibly existing one
            $cache_file->spurt(
                encode_json(
                    {
                        data        => \@assets,
                        groups      => \%group_info,
                        parents     => \%parent_group_info,
                        last_update => now() . 'Z',
                    }));
            rename($new_cache_file_path, $cache_file_path) or die $!;
        }
        catch {
            log_warning("Unable to create cache file $cache_file_path: $@");
        };
    }

    return {assets => \@assets, groups => \%group_info, parents => \%parent_group_info};
}

sub untie_asset_from_job_and_unregister_if_unused ($self, $type, $name, $job) {
    $self->result_source->schema->txn_do(
        sub {
            my %query = (type => $type, name => $name, fixed => 0);
            return 0 unless my $asset = $self->find(\%query, {join => 'jobs_assets'});
            $job->jobs_assets->search({asset_id => $asset->id})->delete;
            return 0 if defined $asset->size || $asset->jobs->count;
            $asset->delete;
            return 1;
        });
}

1;
