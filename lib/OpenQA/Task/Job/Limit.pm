# Copyright (C) 2018-2021 SUSE LLC
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

use OpenQA::Log 'log_debug';
use OpenQA::ScreenshotDeletion;
use OpenQA::Utils qw(:DEFAULT resultdir check_df);
use OpenQA::Task::Utils qw(finish_job_if_disk_usage_below_percentage);
use Scalar::Util 'looks_like_number';
use List::Util 'min';
use Time::Seconds;

# define default parameters for batch processing
use constant DEFAULT_SCREENSHOTS_PER_BATCH  => 200000;
use constant DEFAULT_BATCHES_PER_MINION_JOB => 450;

sub register {
    my ($self, $app) = @_;
    my $minion = $app->minion;
    $minion->add_task(limit_results_and_logs         => \&_limit);
    $minion->add_task(limit_screenshots              => \&_limit_screenshots);
    $minion->add_task(ensure_results_below_threshold => \&_ensure_results_below_threshold);
}

sub _limit {
    my ($job, $args) = @_;

    # prevent multiple limit_results_and_logs tasks and limit_screenshots_task/archive_job_results to run in parallel
    my $app = $job->app;
    return $job->retry({delay => ONE_MINUTE})
      unless my $process_job_results_guard = $app->minion->guard('process_job_results_task', ONE_DAY);
    return $job->finish('Previous limit_results_and_logs job is still active')
      unless my $limit_results_and_logs_guard = $app->minion->guard('limit_results_and_logs_task', ONE_DAY);
    return $job->finish('Previous limit_screenshots_task job is still active')
      unless my $limit_screenshots_guard = $app->minion->guard('limit_screenshots_task', ONE_DAY);

    # prevent multiple limit_* tasks to run in parallel
    return $job->retry({delay => ONE_MINUTE})
      unless my $overall_limit_guard = $app->minion->guard('limit_tasks', ONE_DAY);

    return undef
      if finish_job_if_disk_usage_below_percentage(
        job     => $job,
        setting => 'result_cleanup_max_free_percentage',
        dir     => resultdir,
      );

    # create temporary job group outside of DB to collect
    # jobs without job_group_id
    my $schema = $app->schema;
    $schema->resultset('JobGroups')->new({})->limit_results_and_logs;

    my $groups  = $schema->resultset('JobGroups');
    my $gru     = $app->gru;
    my %options = (priority => 0, ttl => 2 * ONE_DAY);
    while (my $group = $groups->next) {
        my $preserved_important_jobs;
        $group->limit_results_and_logs(\$preserved_important_jobs);

        # archive openQA jobs where logs were preserved because they are important
        if ($preserved_important_jobs) {
            for my $job ($preserved_important_jobs->all) {
                $gru->enqueue(archive_job_results => [$job->id], \%options) if $job->archivable_result_dir;
            }
        }
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
    my @screenshot_cleanup_info;
    my @parent_minion_job_ids = ($job->id);
    for (my $i = $min_id; $i < $max_id; $i += $screenshots_per_minion_job) {
        my %args = (
            min_screenshot_id     => $i,
            max_screenshot_id     => min($max_id, $i + $screenshots_per_minion_job - 1),
            screenshots_per_batch => $screenshots_per_batch,
        );
        my $ids = $gru->enqueue(limit_screenshots => \%args, \%options);
        push(@screenshot_cleanup_info, \%args);
        push(@parent_minion_job_ids,   $ids->{minion_id});
    }
    $job->note(screenshot_cleanup => \@screenshot_cleanup_info);
    $gru->enqueue(ensure_results_below_threshold => {}, {parents => \@parent_minion_job_ids})
      if $config->{results_min_free_disk_space_percentage};
}

sub _limit_screenshots {
    my ($job, $args) = @_;

    # prevent multiple limit_screenshots tasks to run in parallel
    my $app = $job->app;
    return $job->retry({delay => ONE_MINUTE})
      unless my $limit_screenshots_guard = $app->minion->guard('limit_screenshots_task', ONE_DAY);

    # prevent multiple limit_* tasks to run in parallel
    return $job->retry({delay => ONE_MINUTE})
      unless my $overall_limit_guard = $app->minion->guard('limit_tasks', ONE_DAY);

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
    my $screenshot_deletion = OpenQA::ScreenshotDeletion->new(dbh => $dbh);
    for (my $i = $min_id; $i <= $max_id; $i += $screenshots_per_batch) {
        log_debug "Removing screenshot batch $i";
        $unused_screenshots_query->execute($i, min($max_id, $i + $screenshots_per_batch - 1));
        $screenshot_deletion->delete_screenshot(@$_) for @{$unused_screenshots_query->fetchall_arrayref};
    }
}

sub _check_remaining_disk_usage {
    my ($job, $resultdir, $min_free_percentage) = @_;

    my ($available_bytes, $total_bytes) = check_df($resultdir);
    my $free_percentage   = $available_bytes / $total_bytes * 100;
    my $margin_percentage = $free_percentage - $min_free_percentage;
    my $margin_bytes      = $margin_percentage / 100 * $total_bytes;
    $job->note(available_bytes   => $available_bytes);
    $job->note(total_bytes       => $total_bytes);
    $job->note(margin_percentage => $margin_percentage);
    $job->note(margin_bytes      => $margin_bytes);
    return $margin_bytes;
}

sub _ensure_results_below_threshold {
    my ($job, $args) = @_;

    # prevent multiple limit_* tasks to run in parallel
    my $app = $job->app;
    return $job->retry({delay => ONE_MINUTE})
      unless my $overall_limit_guard = $app->minion->guard('limit_tasks', ONE_DAY);

    # load configured free percentage
    my $min_free_percentage = $job->app->config->{misc_limits}->{results_min_free_disk_space_percentage};
    return $job->finish('No minimum free disk space percentage configured') unless defined $min_free_percentage;
    return $job->fail('Configured minimum free disk space is not a number between 0 and 100')
      unless looks_like_number($min_free_percentage) && $min_free_percentage >= 0 && $min_free_percentage <= 100;

    # check free percentage
    # caveat: We're using `df` here which might not be appropriate for any filesystem, e.g. one might want
    #         to use `btrfs filesystem df …` instead. It is conceivable to allow running a custom script here
    #         instead.
    my $resultdir    = resultdir;
    my $margin_bytes = 0;
    my $df_chk       = sub {
        $margin_bytes = _check_remaining_disk_usage($job, $resultdir, $min_free_percentage);
        return $margin_bytes >= 0;
    };
    $job->note(resultdir => $resultdir);
    return $job->finish('Done, nothing to do') if $df_chk->();

    # determine the last job *before* determining important builds
    # note: If a new important build is scheduled while the cleanup is ongoing we must not accidentally clean these
    #       jobs up because our list of important builds is outdated. It would be possible to use a transaction
    #       to avoid this. However, this would make things more complicated because the actual screenshot deletion
    #       must *not* run within that transaction so we needed to determine non-important jobs upfront. This
    #       would eliminate the possibility to query jobs in ranges for better scalability. (The screenshot
    #       deletion must not run within the transaction because we rely on getting a foreign key violation to
    #       prevent deleting a screenshot which has in the meantime been linked to a new job. This conflict must
    #       not only occur at the end of the transaction.)
    my $schema = $app->schema;
    my ($max_job_id) = $schema->storage->dbh->selectrow_array('select max(id) from jobs');
    return $job->finish('Done, no jobs present') unless $max_job_id;

    # determine important builds (for each group)
    my $job_groups = $schema->resultset('JobGroups');
    my %important_builds_hash;
    for my $job_group ($job_groups->all) {
        $important_builds_hash{$_} = 1 for @{$job_group->important_builds};
    }
    my @important_builds = keys %important_builds_hash;
    $job->note(important_builds => \@important_builds);

    # caveat: The subsequent cleanup simply deletes stuff from old jobs first. It does not take the retention periods
    #         configured on job group level into account anymore.
    # caveat: We're considering possibly lots of jobs at once here. Maybe we need to select a range here when dealing
    #         with a huge number of jobs.

    log_debug "Deleting videos from non-important jobs startinng from oldest job (balance is $margin_bytes)";
    my $jobs        = $schema->resultset('Jobs');
    my @job_id_args = (id       => {'<=' => $max_job_id});
    my %jobs_params = (order_by => {-asc => 'id'});
    my $relevant_jobs
      = $jobs->search({@job_id_args, logs_present => 1, BUILD => {-not_in => \@important_builds}}, \%jobs_params);
    while (my $openqa_job = $relevant_jobs->next) {
        log_debug 'Deleting video of job ' . $openqa_job->id;
        return $job->finish('Done after deleting videos from non-important jobs')
          if ($margin_bytes += $openqa_job->delete_videos) >= 0;
    }

    log_debug "Deleting results from non-important jobs startinng from oldest job (balance is $margin_bytes)";
    $relevant_jobs = $jobs->search({@job_id_args, BUILD => {-not_in => \@important_builds}}, \%jobs_params);
    while (my $openqa_job = $relevant_jobs->next) {
        log_debug 'Deleting results of job ' . $openqa_job->id;
        return $job->finish('Done after deleting results from non-important jobs')
          if ($margin_bytes += $openqa_job->delete_results) >= 0;
    }

    log_debug "Deleting videos from important jobs startinng from oldest job (balance is $margin_bytes)";
    $relevant_jobs
      = $jobs->search({@job_id_args, logs_present => 1, BUILD => {-in => \@important_builds}}, \%jobs_params);
    while (my $openqa_job = $relevant_jobs->next) {
        log_debug 'Deleting video of important job ' . $openqa_job->id;
        return $job->finish('Done after deleting videos from important jobs')
          if ($margin_bytes += $openqa_job->delete_videos) >= 0;
    }

    log_debug "Deleting results from important jobs startinng from oldest job (balance is $margin_bytes)";
    $relevant_jobs = $jobs->search({@job_id_args, BUILD => {-in => \@important_builds}}, \%jobs_params);
    while (my $openqa_job = $relevant_jobs->next) {
        log_debug 'Deleting results of important job ' . $openqa_job->id;
        return $job->finish('Done after deleting results from important jobs')
          if ($margin_bytes += $openqa_job->delete_results) >= 0;
    }

    return $job->fail('Unable to cleanup enough results');
}

1;
