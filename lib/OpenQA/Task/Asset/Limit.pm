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

package OpenQA::Task::Asset::Limit;
use Mojo::Base 'Mojolicious::Plugin';

use OpenQA::Utils;
use Mojo::URL;

sub register {
    my ($self, $app) = @_;
    $app->minion->add_task(limit_assets => sub { _limit($app, @_) });
}

sub _remove_if {
    my ($db, $asset) = @_;
    return if $asset->{fixed} || $asset->{pending};
    $db->resultset('Assets')->single({id => $asset->{id}})->delete;
}

sub _limit {
    my ($app, $j, $job, $url) = @_;

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
