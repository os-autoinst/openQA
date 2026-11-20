# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::Job::LeftoverResults;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use Mojo::File qw(path);
use OpenQA::Log qw(log_info);
use OpenQA::Task::Job::Limit ();
use OpenQA::Task::SignalGuard;
use OpenQA::Utils qw(archivedir resultdir);
use Time::Seconds;

sub register ($self, $app, @args) {
    $app->minion->add_task(delete_leftover_results => \&_delete_leftover_results);
}

sub _delete_leftover_results ($job, $args = undef) {
    my $signal_guard = OpenQA::Task::SignalGuard->new($job);
    my $jobs_rs = $job->app->schema->resultset('Jobs');
    my ($checked, $removed) = _remove_leftover_results($jobs_rs, path(resultdir), $signal_guard);
    my $removed_copies = _remove_aborted_copies(path(archivedir, 'testresults'), $signal_guard);
    log_info "Removed $removed of $checked leftover result directories and $removed_copies aborted archive copies";
    $job->note(checked_result_dirs => $checked);
    $job->note(removed_result_dirs => $removed);
    $job->note(removed_aborted_copies => $removed_copies);
    return undef;
}

sub _remove_leftover_results ($jobs_rs, $results_dir, $signal_guard) {
    return (0, 0) unless -d $results_dir;

    # a prefix directory contains at most 1000 job directories so one query per prefix directory is enough
    my ($checked, $removed) = (0, 0);
    my $batches_left = OpenQA::Task::Job::Limit::DEFAULT_BATCHES_PER_MINION_JOB;
    for my $prefix_dir ($results_dir->list({dir => 1})->grep(qr{/\d{5}$})->each) {
        last unless $batches_left--;
        my @result_dirs = $prefix_dir->list({dir => 1})->grep(qr{/\d+-\S+$})->each;
        my %id_of_dir = map { my $name = $_->basename; ($name =~ /^(\d+)-/) ? ($name => $1) : () } @result_dirs;
        my %archived
          = map { $_->id => 1 } $jobs_rs->search({archived => 1, id => {-in => [values %id_of_dir]}})->all;
        $checked += @result_dirs;
        for my $dir (grep { $archived{$id_of_dir{$_->basename}} } @result_dirs) {
            $signal_guard->retry(0);
            $dir->remove_tree;
            $removed++;
        }
    }
    return ($checked, $removed);
}

sub _remove_aborted_copies ($archive_dir, $signal_guard) {
    return 0 unless -d $archive_dir;

    # aborted copies are only removed when they are old enough to not belong to an in-flight archiving job
    my $now = time;
    my $removed = 0;
    for my $prefix_dir ($archive_dir->list({dir => 1})->each) {
        for my $copy ($prefix_dir->list({dir => 1})->grep(qr{\.(?:partial|stale)\.\d+$})->each) {
            # an archiving job may publish the copy right now, so it can be gone before its age is checked
            my $stat = $copy->stat or next;
            next if $now - $stat->mtime < ONE_DAY;
            $signal_guard->retry(0);
            $copy->remove_tree;
            $removed++;
        }
    }
    return $removed;
}

1;
