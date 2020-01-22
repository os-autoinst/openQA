# Copyright (C) 2018-2019 SUSE LLC
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

package OpenQA::Task::Job::Limit;
use Mojo::Base 'Mojolicious::Plugin';

use File::Spec::Functions 'catfile';
use File::Basename qw(basename dirname);
use OpenQA::Utils qw(:DEFAULT imagesdir);

sub register {
    my ($self, $app) = @_;
    $app->minion->add_task(limit_results_and_logs => sub { _limit($app, @_) });
}

sub _limit {
    my ($app, $job) = @_;

    # prevent multiple limit_results_and_logs tasks to run in parallel
    return $job->finish('Previous limit_results_and_logs job is still active')
      unless my $guard = $app->minion->guard('limit_results_and_logs_task', 86400);

    # prevent multiple limit_* tasks to run in parallel
    return $job->retry({delay => 60})
      unless my $limit_guard = $app->minion->guard('limit_tasks', 86400);

    # create temporary job group outside of DB to collect
    # jobs without job_group_id
    my $schema = $app->schema;
    $schema->resultset('JobGroups')->new({})->limit_results_and_logs;

    my $groups = $schema->resultset('JobGroups');
    while (my $group = $groups->next) {
        $group->limit_results_and_logs;
    }

    # delete unused screenshots in batches
    my $storage = $schema->storage;
    my $dbh     = $storage->dbh;
    my ($min_id, $max_id) = $dbh->selectrow_array('select min(id), max(id) from screenshots');
    my $screenshots_with_ref_count_query_limit = 200000;
    my $delete_screenshot_query                = $dbh->prepare('DELETE FROM screenshots WHERE id = ?');
    my $unused_screenshots_query               = $dbh->prepare(
        'SELECT me.id, me.filename
         FROM screenshots me
         LEFT OUTER JOIN screenshot_links links_outer
         ON links_outer.screenshot_id = me.id
         WHERE me.id BETWEEN ? AND ?
         AND links_outer.screenshot_id is NULL'
    );
    for (my $i = $min_id; $i <= $max_id; $i += $screenshots_with_ref_count_query_limit) {
        $unused_screenshots_query->execute($i, $i + $screenshots_with_ref_count_query_limit);
        while (my $screenshot = $unused_screenshots_query->fetchrow_arrayref) {
            my $screenshot_filename = $screenshot->[1];
            my $imagesdir           = imagesdir();
            my $screenshot_path     = catfile($imagesdir, $screenshot_filename);
            my $thumb_path
              = catfile($imagesdir, dirname($screenshot_filename), '.thumbs', basename($screenshot_filename));
            log_debug("removing screenshot $screenshot_filename");

            # delete screenshot in database first
            # note: This might fail due to foreign key violation because a new screenshot link might
            #       have just been created. In this case the screenshot should not be deleted in the
            #       database or the file system.
            eval { $delete_screenshot_query->execute($screenshot->[0]); };
            next if $@;

            # delete screenshot in file system
            unless (unlink($screenshot_path) || !-f $screenshot_path) {
                log_debug("can't remove $screenshot_filename");
            }
            unless (unlink($thumb_path) || !-f $thumb_path) {
                log_debug("can't remove $thumb_path");
            }
        }
    }
}


1;
