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

package OpenQA::Schema::ResultSet::Assets;
use strict;
use base 'DBIx::Class::ResultSet';
use OpenQA::Utils qw(log_warning locate_asset human_readable_size);
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
    my $asset = $self->find_or_create(
        {
            type => $type,
            name => $name,
        },
        {
            key => 'assets_type_name',
        });
    return $asset;
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

sub status {
    my ($self) = @_;

    $self->scan_for_untracked_assets();

    my $rsource = $self->result_source;
    my $schema  = $rsource->schema;

    # prefetch all assets
    my %asset_info;
    while (my $as = $self->next) {
        if ($as->is_fixed) {
            $as->update({fixed => 1});
        }
        else {
            $as->update({fixed => 0});
        }
        my $age     = $as->t_created->delta_ms(DateTime->now)->in_units('minutes');
        my $dirname = $as->type . '/';
        if ($as->fixed) { $dirname .= 'fixed/'; }
        $asset_info{$as->id} = {
            id      => $as->id,
            fixed   => $as->fixed,
            pending => 0,
            size    => $as->ensure_size,
            name    => $dirname . $as->name,
            age     => $age,
            max_job => 0,
            groups  => {}};
    }

    # these queries are just too much for dbix. note the sort order here:
    # we sort the assets in descending order by highest related job ID,
    # so assets for recent jobs are considered first (and most likely to be kept)
    my $stm = <<'END_SQL';
         select a.*,max(j.id) from jobs_assets ja
              join jobs j on j.id=ja.job_id
              join assets a on a.id=ja.asset_id
           where j.group_id=?
           group by a.id
           order by max desc;
END_SQL
    my $dbh            = $schema->storage->dbh;
    my $job_assets_sth = $dbh->prepare($stm);

    # query list of job groups to show assets by job group
    # We collect data required for /admin/assets *and* the limit_assets task
    my $groups = $schema->resultset('JobGroups');
    my %group_infos;
    $group_infos{0} = {size_limit_gb => 0, size => 0, group => 'Untracked', id => undef};

    # find relevant assets which belong to a job group
    while (my $g = $groups->next) {
        my $group_id = $g->id;

        $group_infos{$g->id}->{size_limit_gb} = $g->size_limit_gb;
        $group_infos{$g->id}->{size}          = $g->size_limit_gb * 1024 * 1024 * 1024;
        $group_infos{$g->id}->{picked}        = 0;
        $group_infos{$g->id}->{id}            = $g->id;
        $group_infos{$g->id}->{group}         = $g->full_name;

        $job_assets_sth->execute($group_id);

        while (my $a = $job_assets_sth->fetchrow_hashref) {
            my $ai = $asset_info{$a->{id}};

            # ignore assets arriving in between - API can register new ones
            next unless $ai;

            $ai->{groups}->{$group_id} = $a->{max};
            if ($a->{max} > $ai->{max_job}) {
                $ai->{max_job} = $a->{max};
            }
        }
    }

    my $pending
      = $schema->resultset('Jobs')->search({state => [OpenQA::Schema::Result::Jobs::PENDING_STATES]})->get_column('id')
      ->as_query;
    my @pendassets
      = $schema->resultset('JobsAssets')->search({job_id => {-in => $pending}})->get_column('asset_id')->all;
    for my $id (@pendassets) {
        my $ai = $asset_info{$id};

        # ignore assets arriving in between - API can register new ones
        next unless $ai;
        $ai->{pending} = 1;
    }

    # sort the assets by importance
    my @assets = values(%asset_info);
    @assets = sort { $b->{max_job} <=> $a->{max_job} || $a->{age} <=> $b->{age} } @assets;

    for my $asset (@assets) {
        my $largest_group = 0;
        my $largest_size  = 0;
        my @groups        = sort { $a <=> $b } keys %{$asset->{groups}};
        for my $g (@groups) {
            if ($largest_size < $group_infos{$g}->{size} && $group_infos{$g}->{size} >= $asset->{size}) {
                $largest_size  = $group_infos{$g}->{size};
                $largest_group = $g;
            }
        }
        $asset->{picked_into} = $largest_group;
        $group_infos{$largest_group}->{size} -= $asset->{size};
        $group_infos{$largest_group}->{picked} += $asset->{size};
    }

    return {assets => \@assets, groups => \%group_infos};
}

1;
