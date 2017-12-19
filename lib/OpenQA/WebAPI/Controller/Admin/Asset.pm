# Copyright (C) 2014 SUSE Linux Products GmbH
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

package OpenQA::WebAPI::Controller::Admin::Asset;
use Mojo::Base 'Mojolicious::Controller';

sub index {
    my $self = shift;

    # query assets
    my $assets = $self->db->resultset('Assets');
    my $assets_ordered_by_id = $assets->search(undef, {order_by => 'id', prefetch => 'jobs_assets'});

    # query list of job groups to show assets by job group
    my @assets_by_group;
    my $groups
      = $self->db->resultset('JobGroups')->search(undef, {order_by => {-desc => 'exclusively_kept_asset_size'}});
    my $dbh                = $self->db->storage->dbh;
    my $query_group_assets = $dbh->prepare(
        'select a.* from assets a join jobs j on j.id = a.last_use_job_id where j.group_id = ? order by a.size desc;');
    while (my $group = $groups->next) {
        my @group_assets;
        $query_group_assets->execute($group->id);
        while (my $asset = $query_group_assets->fetchrow_hashref) {
            push(@group_assets, $asset);
        }
        push(
            @assets_by_group,
            {
                id     => $group->id,
                name   => $group->name,
                size   => $group->exclusively_kept_asset_size,
                assets => \@group_assets,
            });
    }

    $self->stash('assets',          $assets_ordered_by_id);
    $self->stash('assets_by_group', \@assets_by_group);
    $self->render('admin/asset/index');
}

1;
