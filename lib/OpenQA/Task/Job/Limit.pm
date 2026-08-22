# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::Job::Limit;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use OpenQA::Jobs::Constants;
use OpenQA::Log qw(log_debug log_info log_warning);
use OpenQA::ScreenshotDeletion;
use OpenQA::Utils qw(:DEFAULT prjdir resultdir archivedir check_df);
use OpenQA::Task::Utils
  qw(acquire_limit_lock_or_retry finish_job_if_storage_usage_below_percentage is_storage_usage_below_percentage);
use OpenQA::Task::SignalGuard;
use Scalar::Util 'looks_like_number';
use List::Util 'min';
use Time::Seconds;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::File;
use Feature::Compat::Try;

# define default parameters for batch processing
use constant DEFAULT_SCREENSHOTS_PER_BATCH => 200000;
use constant DEFAULT_BATCHES_PER_MINION_JOB => 450;

sub register ($self, $app, @args) {
    my $minion = $app->minion;
    $minion->add_task(limit_results_and_logs => \&_limit);
    $minion->add_task(limit_screenshots => \&_limit_screenshots);
    $minion->add_task(ensure_results_below_threshold => \&_ensure_results_below_threshold);
}

sub _limit ($job, $args = undef) {
    my $ensure_task_retry_on_termination_signal_guard = OpenQA::Task::SignalGuard->new($job);

    # prevent multiple limit_results_and_logs tasks and limit_screenshots_task/archive_job_results to run in parallel
    my $app = $job->app;
    my $archiving_cfg = $app->config->{archiving};
    my $min_free = $archiving_cfg->{archive_important_jobs_min_free_percentage};
    my $keep_free = $archiving_cfg->{archive_keep_free_percentage};
    my $max_dur = $archiving_cfg->{archive_max_duration};

    return $job->fail(_format_percentage_error(archive_important_jobs_min_free_percentage => $min_free))
      unless _is_valid_percentage($min_free);
    return $job->fail(_format_percentage_error(archive_keep_free_percentage => $keep_free))
      unless _is_valid_percentage($keep_free);
    return $job->fail("Configured archive_max_duration ($max_dur) is not a non-negative number")
      if !looks_like_number($max_dur) || $max_dur < 0;

    return $job->retry({delay => ONE_MINUTE})
      unless my $process_job_results_guard = $app->minion->guard('process_job_results_task', ONE_DAY);
    return $job->finish('Previous limit_results_and_logs job is still active')
      unless my $limit_results_and_logs_guard = $app->minion->guard('limit_results_and_logs_task', ONE_DAY);
    return $job->finish('Previous limit_screenshots_task job is still active')
      unless my $limit_screenshots_guard = $app->minion->guard('limit_screenshots_task', ONE_DAY);

    return undef unless my $limit_guard = acquire_limit_lock_or_retry($job);

    return undef
      if finish_job_if_storage_usage_below_percentage(
        job => $job,
        setting => 'result_cleanup_max_free_percentage',
        dir => resultdir,
      );

    my $schema = $app->schema;
    _archive_important_jobs_upfront($job, $archiving_cfg, $min_free, $keep_free, $max_dur);

    # create temporary job group outside of DB to collect
    # jobs without job_group_id
    $schema->resultset('JobGroups')->new({})->limit_results_and_logs;

    my $cache_file_path = prjdir() . '/webui/cache/cleanup-status.json';
    my $last_id;
    if (-f $cache_file_path) {
        try {
            my $content = Mojo::File->new($cache_file_path)->slurp;
            my $data = decode_json($content);
            $last_id = $data->{last_processed_job_group_id};
            log_debug "Resuming job group cleanup after group ID $last_id" if $last_id;
        }
        catch ($e) {
            log_warning("Unable to read cleanup status from $cache_file_path: $e");
        }
    }

    my $groups_rs = $schema->resultset('JobGroups')->search(undef, {order_by => 'id ASC'});
    my @all_groups = $groups_rs->all;

    if (defined $last_id) {
        my @greater_than = grep { $_->id > $last_id } @all_groups;
        my @less_or_equal = grep { $_->id <= $last_id } @all_groups;
        @all_groups = (@greater_than, @less_or_equal);
    }

    my $groups_count = scalar @all_groups;
    log_info "Starting cleanup for $groups_count job groups";

    my $gru = $app->gru;
    my %options = (priority => -20, ttl => 2 * ONE_DAY);
    my $last_processed_id;
    for my $group (@all_groups) {
        if (
            my $msg = is_storage_usage_below_percentage(
                job => $job,
                setting => 'result_cleanup_max_free_percentage',
                dir => resultdir
            ))
        {
            log_info "Early abort during job groups loop (halted before processing group '@{[$group->name]}'): $msg";
            $job->note(early_abort_results => $msg);
            last;
        }
        my @preserved_important_jobs;
        $group->limit_results_and_logs(\@preserved_important_jobs);

        # archive openQA jobs that were preserved because they are important
        $gru->enqueue(archive_job_results => [$_->id], \%options) for @preserved_important_jobs;

        $last_processed_id = $group->id;
    }

    if (defined $last_processed_id) {
        try {
            my $cache_file = Mojo::File->new("$cache_file_path.new");
            $cache_file->dirname->make_path();
            $cache_file->spew(encode_json({last_processed_job_group_id => $last_processed_id}))
              ->move_to($cache_file_path);
            log_debug "Saved cleanup status: last processed group ID is $last_processed_id";
        }
        catch ($e) {
            log_warning("Unable to write cleanup status to $cache_file_path: $e");
        }
    }

    $ensure_task_retry_on_termination_signal_guard->retry(0);

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
    my $config = $app->config->{misc_limits};
    my $screenshots_per_batch = $args->{screenshots_per_batch} // $config->{screenshot_cleanup_batch_size};
    my $batches_per_minion_job = $args->{batches_per_minion_job}
      // $config->{screenshot_cleanup_batches_per_minion_job};
    my $screenshots_per_minion_job = $batches_per_minion_job * $screenshots_per_batch;
    my @screenshot_cleanup_info;
    my @parent_minion_job_ids = ($job->id);
    for (my $i = $min_id; $i < $max_id; $i += $screenshots_per_minion_job) {
        my %args = (
            min_screenshot_id => $i,
            max_screenshot_id => min($max_id, $i + $screenshots_per_minion_job - 1),
            screenshots_per_batch => $screenshots_per_batch,
        );
        my $ids = $gru->enqueue(limit_screenshots => \%args, \%options);
        push @screenshot_cleanup_info, \%args;
        push @parent_minion_job_ids, $ids->{minion_id};
    }
    $job->note(screenshot_cleanup => \@screenshot_cleanup_info);
    $gru->enqueue(ensure_results_below_threshold => {}, {parents => \@parent_minion_job_ids})
      if $config->{result_cleanup_min_free_percentage} or $config->{archive_cleanup_min_free_percentage};
}

sub _limit_screenshots ($job, $args) {
    my $ensure_task_retry_on_termination_signal_guard = OpenQA::Task::SignalGuard->new($job);

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
    my $dbh = $app->schema->storage->dbh;
    my $delete_screenshot_query = $dbh->prepare('DELETE FROM screenshots WHERE id = ?');
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

sub _check_remaining_storage_usage ($job, $resultdir, $min_free_percentage) {
    return 0 unless defined $min_free_percentage;
    my ($available_bytes, $total_bytes) = check_df($resultdir);
    my $free_percentage = $available_bytes / $total_bytes * 100;
    my $margin_percentage = $free_percentage - $min_free_percentage;
    my $margin_bytes = $margin_percentage / 100 * $total_bytes;
    $job->note(available_bytes => $available_bytes);
    $job->note(total_bytes => $total_bytes);
    $job->note(margin_percentage => $margin_percentage);
    $job->note(margin_bytes => $margin_bytes);
    return $margin_bytes;
}

sub _is_valid_percentage ($value) { looks_like_number($value) && $value >= 0 && $value <= 100 }

sub _format_percentage_error ($key, $value) {
    "Configured $key ($value) is not a number between 0 and 100";
}

sub _account_for_deletion ($margin_bytes, $margin_bytes_main_storage, $deleted_results, $deleted_screenshots = 0) {
    $$margin_bytes += $deleted_results;
    $$margin_bytes_main_storage += $deleted_screenshots;
    return $$margin_bytes >= 0;
}

my %PLURALS = (video => 'videos', results => 'results');
my %JOB_PREFIXES = ('non-important' => '', important => 'important ');

sub _delete_jobs ($what, $job_specifier, $search_conds, $jobs, $from, $margin_bytes, $margin_bytes_main_storage, $dry) {
    log_debug
      "Deleting $what from $job_specifier jobs starting from oldest job (from $from, balance is $$margin_bytes)";
    my $action = "delete_$PLURALS{$what}";
    my $log_message = "Deleting $what of $JOB_PREFIXES{$job_specifier}job ";
    for my $openqa_job ($jobs->search($search_conds, {order_by => {-asc => 'id'}})) {
        log_debug $log_message . $openqa_job->id;
        return (1, "Done with $from after deleting $PLURALS{$what} from $job_specifier jobs")
          if _account_for_deletion $margin_bytes, $margin_bytes_main_storage, $openqa_job->$action($dry);
    }
    return ();
}

sub _delete_results ($dry, $jobs, $max_job_id, $not_important_cond, $important_cond, $margin_bytes,
    $margin_bytes_main_storage, $archived)
{
    # caveat: The subsequent cleanup simply deletes stuff from old jobs first. It does not take the retention periods
    #         configured on job group level into account anymore.
    # caveat: We're considering possibly lots of jobs at once here. Maybe we need to select a range here when dealing
    #         with a huge number of jobs.

    my $from = $archived ? 'archive' : 'results dir';
    return (1, "Nothing to do for $from") if $$margin_bytes >= 0;

    my @search = (id => {'<=' => $max_job_id}, archived => $archived);
    my @common = ($jobs, $from, $margin_bytes, $margin_bytes_main_storage, $dry);
    my @res;
    for my $step_args (
        ['video', 'non-important', {@search, @$not_important_cond, logs_present => 1}, @common],
        ['results', 'non-important', {@search, @$not_important_cond}, @common],
        ['video', 'important', {@search, @$important_cond, logs_present => 1}, @common],
        ['results', 'important', {@search, @$important_cond}, @common],
      )
    {
        return @res if @res = _delete_jobs(@$step_args);
    }
    return (0, "Unable to cleanup enough results from $from");
}

sub _build_important_conditions ($schema, $job = undef) {
    my @groups = $schema->resultset('JobGroups')->all;
    my %important_builds_with_version = map { $_ => 1 } map { @{$_->important_builds->[0]} } @groups;
    my %important_builds_without_version = map { $_ => 1 } map { @{$_->important_builds->[1]} } @groups;

    my @important_builds_with_version = keys %important_builds_with_version;
    my @important_builds_without_version = keys %important_builds_without_version;
    my @important_cond = (
        -or => [
            TAG_ID_COLUMN, => {-in => \@important_builds_with_version},
            BUILD => {-in => \@important_builds_without_version}]);
    my @not_important_cond = (
        TAG_ID_COLUMN, => {-not_in => \@important_builds_with_version},
        BUILD => {-not_in => \@important_builds_without_version});
    if ($job) {
        $job->note(important_builds_with_version => \@important_builds_with_version);
        $job->note(important_builds_without_version => \@important_builds_without_version);
    }
    return (\@not_important_cond, \@important_cond);
}

sub _archive_important_jobs_upfront ($job, $archiving_cfg, $min_free, $keep_free, $max_dur) {
    return if !$archiving_cfg->{archive_preserved_important_jobs} || $min_free <= 0;
    my $app = $job->app;
    my $res_dev = (stat resultdir())[0];
    my $ar_dev = (stat archivedir())[0];
    if (!$ENV{HARNESS_ACTIVE} && $app->mode !~ /^test/ && defined $res_dev && defined $ar_dev && $res_dev == $ar_dev) {
        $job->note(archived_jobs => 0);
        $job->note(archiving_stopped => 'resultdir and archivedir are on the same device');
        return;
    }

    my $start_time = time;
    my $schema = $app->schema;
    my $jobs_rs = $schema->resultset('Jobs');
    my ($not_important_cond, $important_cond) = _build_important_conditions($schema);
    my $archive_jobs_count = 0;
    my $archiving_stopped_reason = '';
    my @skipped_ids;

    while (1) {
        if ($max_dur > 0 && (time - $start_time) >= $max_dur) {
            $archiving_stopped_reason = 'time budget exceeded';
            last;
        }
        my ($available_res, $total_res) = check_df(resultdir());
        my $free_res_percentage = $available_res / $total_res * 100;
        if ($free_res_percentage >= $min_free) {
            $archiving_stopped_reason = 'results threshold reached';
            last;
        }
        my ($available_ar, $total_ar) = check_df(archivedir());
        my $free_ar_percentage = $available_ar / $total_ar * 100;
        if ($free_ar_percentage <= $keep_free) {
            $archiving_stopped_reason = 'archive floor reached';
            last;
        }
        my $candidate = $jobs_rs->search(
            {
                @$important_cond,
                archived => 0,
                state => {-in => [FINAL_STATES]},
                (@skipped_ids ? (id => {-not_in => \@skipped_ids}) : ()),
            },
            {order_by => {-asc => 'id'}, rows => 1})->first;
        if (!$candidate) {
            $archiving_stopped_reason = 'no candidates left';
            last;
        }
        my $job_id = $candidate->id;
        my $guard = $app->minion->guard("process_job_results_for_$job_id", ONE_DAY);
        if (!$guard) {
            push @skipped_ids, $job_id;
            next;
        }
        log_info "Archiving important job $job_id";
        try {
            $candidate->archive();
            $archive_jobs_count++;
        }
        catch ($e) {
            log_warning "Failed to archive job $job_id: $e";
            push @skipped_ids, $job_id;
        }
    }
    $job->note(archived_jobs => $archive_jobs_count);
    $job->note(archiving_stopped => $archiving_stopped_reason);
}

sub _ensure_results_below_threshold ($job, @) {
    my $ensure_task_retry_on_termination_signal_guard = OpenQA::Task::SignalGuard->new($job);
    # prevent multiple limit_* tasks to run in parallel
    my $app = $job->app;
    return $job->retry({delay => ONE_MINUTE})
      unless my $overall_limit_guard = $app->minion->guard('limit_tasks', ONE_DAY);

    # load configured free percentage
    my $limits = $job->app->config->{misc_limits};
    my $min_free_percentage = $limits->{result_cleanup_min_free_percentage} // 'none';
    my $min_free_percentage_ar = $limits->{archive_cleanup_min_free_percentage};
    my $dry = $limits->{cleanup_min_free_dry_run};
    return $job->finish('No minimum free storage space percentage configured') if $min_free_percentage eq 'none';
    return $job->fail(_format_percentage_error(result_cleanup_min_free_percentage => $min_free_percentage))
      unless _is_valid_percentage($min_free_percentage);
    return $job->fail(_format_percentage_error(archive_cleanup_min_free_percentage => $min_free_percentage_ar))
      if defined $min_free_percentage_ar && !_is_valid_percentage($min_free_percentage_ar);

    # check free percentage
    # caveat: We're using `df` here which might not be appropriate for any filesystem, e.g. one might want
    #         to use `btrfs filesystem df …` instead. It is conceivable to allow running a custom script here
    #         instead.
    my $resultdir = resultdir;
    my $archivedir = archivedir;
    my $margin_bytes = _check_remaining_storage_usage($job, $resultdir, $min_free_percentage);
    my $margin_bytes_ar = _check_remaining_storage_usage($job, $archivedir, $min_free_percentage_ar);
    $job->note(resultdir => $resultdir);
    $job->note(archivedir => $archivedir);
    return $job->finish('Done, nothing to do') if $margin_bytes >= 0 && $margin_bytes_ar >= 0;

    # determine the last job *before* determining important builds
    # note: If a new important build is scheduled while the cleanup is ongoing we must not accidentally clean these
    #       jobs up because our list of important builds is outdated. It would be possible to use a transaction
    #       to avoid this. However, this would make things more complicated because the actual screenshot deletion
    #       must *not* run within such a transaction. So we needed to determine non-important jobs upfront. This
    #       would eliminate the possibility to query jobs in ranges for better scalability. (The screenshot
    #       deletion must not run within a transaction because we rely on getting a foreign key violation to
    #       prevent deleting a screenshot which has in the meantime been linked to a new job.)
    my $schema = $app->schema;
    my ($max_job_id) = $schema->storage->dbh->selectrow_array('select max(id) from jobs');
    return $job->finish('Done, no jobs present') unless $max_job_id;

    # determine important builds (for each group)
    my ($not_important_cond, $important_cond) = _build_important_conditions($schema, $job);

    # delete results as far as necessary on the results dir and the archive dir
    my $jobs = $schema->resultset('Jobs');
    my ($ok_ar, @message_ar)
      = defined $min_free_percentage_ar
      ? _delete_results($dry, $jobs, $max_job_id, $not_important_cond, $important_cond, \$margin_bytes_ar,
        \$margin_bytes, 1)
      : (1);
    my ($ok, @message)
      = _delete_results($dry, $jobs, $max_job_id, $not_important_cond, $important_cond, \$margin_bytes, \$margin_bytes,
        0);
    my $method = $ok && $ok_ar ? 'finish' : 'fail';
    $job->$method(join "\n", @message, @message_ar);
}

1;
