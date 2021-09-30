# Copyright 2018-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::Asset::Limit;
use Mojo::Base 'Mojolicious::Plugin';

use OpenQA::Log qw(log_info log_debug);
use OpenQA::Utils qw(:DEFAULT assetdir);
use OpenQA::Task::Utils qw(acquire_limit_lock_or_retry finish_job_if_disk_usage_below_percentage);

use Mojo::URL;
use Data::Dump 'pp';
use Time::Seconds;
use Try::Tiny;

sub register {
    my ($self, $app) = @_;
    $app->minion->add_task(limit_assets => sub { _limit($app, @_) });
}

sub _remove_if {
    my ($db, $asset, $reason) = @_;
    return if $asset->{fixed} || $asset->{pending};

    if (!$reason) {
        my $asset_name = $asset->{name};
        my $groups = join(', ', keys %{$asset->{groups}});
        my $parents = join(', ', keys %{$asset->{parents}});
        $parents = " within parent job groups $parents" if $parents;
        $reason = "Removing asset $asset_name (belonging to job groups: ${groups}${parents})";
    }
    log_info($reason);

    $db->resultset('Assets')->single({id => $asset->{id}})->delete;
}

sub _update_exclusively_kept_asset_size {
    my ($dbh, $table_name, $parent_or_job_group_info) = @_;

    my $update_sth = $dbh->prepare("UPDATE $table_name SET exclusively_kept_asset_size = ? WHERE id = ?");
    for my $group (values %$parent_or_job_group_info) {
        $update_sth->execute($group->{picked}, $group->{id});
    }
}

sub _limit {
    my ($app, $job) = @_;

    # prevent multiple limit_assets tasks to run in parallel
    return $job->finish('Previous limit_assets job is still active')
      unless my $guard = $app->minion->guard('limit_assets_task', ONE_DAY);

    return undef unless my $limit_guard = acquire_limit_lock_or_retry($job);

    return undef
      if finish_job_if_disk_usage_below_percentage(
        job => $job,
        setting => 'asset_cleanup_max_free_percentage',
        dir => assetdir,
      );

    # scan for untracked assets, refresh the size of all assets
    my $schema = $app->schema;
    try {
        $schema->resultset('Assets')->scan_for_untracked_assets();
        $schema->resultset('Assets')->refresh_assets();

        my $asset_status = $schema->resultset('Assets')->status(
            compute_pending_state_and_max_job => 1,
            compute_max_job_by_group => 1,
            fail_on_inconsistent_status => 1,
            skip_cache_file => 1,
        );
        log_debug pp($asset_status);
        my $assets = $asset_status->{assets};

        # first remove grouped assets
        for my $asset (@$assets) {
            if (keys %{$asset->{groups}} && !$asset->{picked_into}) {
                _remove_if($schema, $asset);
            }
        }

        # use DBD::Pg as dbix doesn't seem to have a direct update call - find()->update are 2 queries
        my $dbh = $app->schema->storage->dbh;
        my $update_sth = $dbh->prepare('UPDATE assets SET last_use_job_id = ? WHERE id = ?');

        # remove all assets older than a certain duration which do not belong to a job group
        my $config = OpenQA::App->singleton->config;
        my $untracked_assets_storage_duration = $config->{misc_limits}->{untracked_assets_storage_duration};
        my $untracked_assets_patterns = $config->{'assets/storage_duration'} // {};
        my $now = DateTime->now();
        for my $asset (@$assets) {
            my ($max_job, $max_job_before) = ($asset->{max_job}, $asset->{last_job});
            $update_sth->execute($max_job && $max_job >= 0 ? $max_job : undef, $asset->{id})
              if !$max_job_before || $max_job != $max_job_before;
            next if $asset->{fixed} || scalar(keys %{$asset->{groups}}) > 0;

            my $asset_name = $asset->{name};
            my $limit_in_days = $untracked_assets_storage_duration;
            for my $pattern (keys %$untracked_assets_patterns) {
                if ($asset_name =~ $pattern) {
                    $limit_in_days = $untracked_assets_patterns->{$pattern};
                    last;
                }
            }

            my $age = DateTime::Format::Pg->parse_datetime($asset->{t_created});
            my $file = Mojo::File->new(assetdir(), $asset_name);
            if (my $stat = $file->stat) {
                my $mtime = DateTime->from_epoch(epoch => $stat->mtime);
                $age = $mtime if $mtime < $age;
            }

            my $age_in_days = $age->delta_days($now)->in_units('days');
            if ($age_in_days >= $limit_in_days) {
                _remove_if($schema, $asset,
                        "Removing asset $asset_name (not in any group, age "
                      . "($age_in_days days) exceeds limit ($limit_in_days days)");
            }
            else {
                my $limit = $age->add(days => $limit_in_days);
                my $remaining_days = $now->delta_days($limit)->in_units('days');
                log_info("Asset $asset_name is not in any job group and will be deleted in $remaining_days days");
            }
        }

        # store the exclusively_kept_asset_size in the DB (e.g. shown in group property editor)
        _update_exclusively_kept_asset_size($dbh, job_groups => $asset_status->{groups});
        _update_exclusively_kept_asset_size($dbh, job_group_parents => $asset_status->{parents});

        # recompute the status (after the cleanup) and produce cache file for /admin/assets
        $schema->resultset('Assets')->status(
            compute_pending_state_and_max_job => 0,
            compute_max_job_by_group => 0,
        );
    }
    catch {
        my $error = $_;

        # retry on errors which are most likely caused by race conditions (we want to avoid locking the tables here)
        if ($error =~ qr/violates (foreign key|unique) constraint/) {
            $job->note(error => $_);
            return $job->retry({delay => ONE_MINUTE});
        }

        $job->fail($error);
    };
}

1;
