# Copyright (C) 2018-2020 SUSE LLC
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
use OpenQA::Log 'log_debug';
use OpenQA::Utils qw(:DEFAULT imagesdir);
use Scalar::Util 'looks_like_number';
use List::Util 'min';

# define default parameters for batch processing
use constant DEFAULT_SCREENSHOTS_PER_BATCH  => 200000;
use constant DEFAULT_BATCHES_PER_MINION_JOB => 450;

sub register {
    my ($self, $app) = @_;
    my $minion = $app->minion;
    $minion->add_task(limit_results_and_logs => \&_limit);
    $minion->add_task(limit_screenshots      => \&_limit_screenshots);
}

sub _limit {
    my ($job, $args) = @_;

    # prevent multiple limit_results_and_logs tasks and limit_screenshots_task to run in parallel
    my $app = $job->app;
    return $job->finish('Previous limit_results_and_logs job is still active')
      unless my $limit_results_and_logs_guard = $app->minion->guard('limit_results_and_logs_task', 86400);
    return $job->finish('Previous limit_screenshots_task job is still active')
      unless my $limit_screenshots_guard = $app->minion->guard('limit_screenshots_task', 86400);

    # prevent multiple limit_* tasks to run in parallel
    return $job->retry({delay => 60})
      unless my $overall_limit_guard = $app->minion->guard('limit_tasks', 86400);

    # create temporary job group outside of DB to collect
    # jobs without job_group_id
    my $schema = $app->schema;
    $schema->resultset('JobGroups')->new({})->limit_results_and_logs;

    my $groups = $schema->resultset('JobGroups');
    while (my $group = $groups->next) {
        $group->limit_results_and_logs;
    }

    # prevent enqueuing new limit_screenshot if there are still inactive/delayed ones
    my $limit_screenshots_jobs
      = $app->minion->jobs({tasks => ['limit_screenshots'], states => ['inactive', 'active']})->total;
    if ($limit_screenshots_jobs > 0) {
        return $job->note(screenshot_cleanup =>
              "skipping, there are still $limit_screenshots_jobs inactive/active limit_screenshots jobs");
    }

    # enqueue further Minion jobs to delete unused screenshots in batches
    my ($min_id, $max_id) = $schema->storage->dbh->selectrow_array('select min(id), max(id) from screenshots');
    return undef unless $min_id && $max_id;
    my $config                 = $app->config->{misc_limits};
    my $screenshots_per_batch  = $args->{screenshots_per_batch} // $config->{screenshot_cleanup_batch_size};
    my $batches_per_minion_job = $args->{batches_per_minion_job}
      // $config->{screenshot_cleanup_batches_per_minion_job};
    my $screenshots_per_minion_job = $batches_per_minion_job * $screenshots_per_batch;
    my $gru                        = $app->gru;
    my %options                    = (priority => 4, ttl => 172800);
    my @screenshot_cleanup_info;
    for (my $i = $min_id; $i < $max_id; $i += $screenshots_per_minion_job) {
        my %args = (
            min_screenshot_id     => $i,
            max_screenshot_id     => min($max_id, $i + $screenshots_per_minion_job - 1),
            screenshots_per_batch => $screenshots_per_batch,
        );
        $gru->enqueue(limit_screenshots => \%args, \%options);
        push(@screenshot_cleanup_info, \%args);
    }
    $job->note(screenshot_cleanup => \@screenshot_cleanup_info);
}

sub _limit_screenshots {
    my ($job, $args) = @_;

    # prevent multiple limit_screenshots tasks to run in parallel
    my $app = $job->app;
    return $job->retry({delay => 60})
      unless my $limit_screenshots_guard = $app->minion->guard('limit_screenshots_task', 86400);

    # prevent multiple limit_* tasks to run in parallel
    return $job->retry({delay => 60})
      unless my $overall_limit_guard = $app->minion->guard('limit_tasks', 86400);

    # validate ID range
    my ($min_id, $max_id, $screenshots_per_batch)
      = ($args->{min_screenshot_id}, $args->{max_screenshot_id}, $args->{screenshots_per_batch});
    return $job->fail({error => 'The specified ID range or screenshots per batch is invalid.'})
      unless looks_like_number($min_id)
      && looks_like_number($max_id)
      && looks_like_number($args->{screenshots_per_batch});

    # delete unused screenshots in batches
    my $dbh                      = $app->schema->storage->dbh;
    my $delete_screenshot_query  = $dbh->prepare('DELETE FROM screenshots WHERE id = ?');
    my $unused_screenshots_query = $dbh->prepare(
        'SELECT me.id, me.filename
         FROM screenshots me
         LEFT OUTER JOIN screenshot_links links_outer
         ON links_outer.screenshot_id = me.id
         WHERE me.id BETWEEN ? AND ?
         AND links_outer.screenshot_id is NULL'
    );
    my $imagesdir = imagesdir();
    for (my $i = $min_id; $i <= $max_id; $i += $screenshots_per_batch) {
        log_debug "Removing screenshot batch $i";
        $unused_screenshots_query->execute($i, min($max_id, $i + $screenshots_per_batch - 1));
        my $screenshots = $unused_screenshots_query->fetchall_arrayref;
        for my $screenshot (@$screenshots) {
            my $screenshot_filename = $screenshot->[1];
            my $screenshot_path     = catfile($imagesdir, $screenshot_filename);
            my $thumb_path
              = catfile($imagesdir, dirname($screenshot_filename), '.thumbs', basename($screenshot_filename));

            # delete screenshot in database first
            # note: This might fail due to foreign key violation because a new screenshot link might
            #       have just been created. In this case the screenshot should not be deleted in the
            #       database or the file system.
            next unless eval { $delete_screenshot_query->execute($screenshot->[0]); 1 };

            # delete screenshot in file system
            unless (unlink($screenshot_path, $thumb_path) == 2) {
                log_debug qq{Can't remove screenshot "$screenshot_filename"} if -f $screenshot_filename;
                log_debug qq{Can't remove thumbnail "$thumb_path"}           if -f $thumb_path;
            }
        }
    }
}

1;
