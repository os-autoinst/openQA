# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Archive;
use Mojo::Base -strict, -signatures;

use Archive::Zip qw(:ERROR_CODES :CONSTANTS);
use Mojo::File 'path';
use Mojo::Util qw(scope_guard);
use OpenQA::Utils qw(resultdir assetdir check_df locate_asset human_readable_size random_hex);
use OpenQA::Log qw(log_info log_error log_debug);
use OpenQA::App;
use File::Basename;
use Feature::Compat::Try;
use Fcntl qw(:flock);

use constant VALID_CATEGORIES => qw(all resultfiles ulogs assets);

# how long a leftover of an interrupted archive creation is kept before it is removed
use constant STALE_ARCHIVE_AGE_SECONDS => 24 * 60 * 60;

sub archive_cache_dir () {
    return $ENV{OPENQA_JOB_DETAILS_ARCHIVE_CACHE_DIR} if $ENV{OPENQA_JOB_DETAILS_ARCHIVE_CACHE_DIR};
    my $config = OpenQA::App->singleton->config->{job_details_archive};
    return $config->{job_details_archive_cache_dir} if $config->{job_details_archive_cache_dir};
    return path(OpenQA::Utils::prjdir(), 'webui', 'cache', 'archives')->to_string;
}

sub get_cache_limit () {
    my $limit_gb = OpenQA::App->singleton->config->{job_details_archive}->{job_details_archive_cache_limit_gb} // 5;
    return $limit_gb * 1024 * 1024 * 1024;
}

sub get_min_free_percentage () {
    return OpenQA::App->singleton->config->{job_details_archive}->{job_details_archive_cache_min_free_percentage} // 10;
}

sub get_watermark_percentage () {
    return OpenQA::App->singleton->config->{job_details_archive}->{job_details_archive_cache_watermark_percentage}
      // 80;
}

sub job_archive_filename ($job_id, $category) {
    return $category eq 'all' ? "job_$job_id.zip" : "job_${job_id}_$category.zip";
}

sub create_job_archive ($job, $category = 'all') {
    my $job_id = $job->id;
    my $cache_dir = path(archive_cache_dir())->make_path;
    my $archive_name = job_archive_filename($job_id, $category);
    my $archive_path = $cache_dir->child($archive_name);
    my $lock_path = $cache_dir->child("$archive_name.lock");
    my $lock_fh = $lock_path->open('>');
    my $lock_guard = scope_guard sub () { close $lock_fh };
    # the lock only serializes creations, so it is dropped as soon as the archive is available;
    # anything else would let a blocked creation start over the same archive name
    my $remove_lock_guard = scope_guard sub () { unlink $lock_path->to_string if -e $archive_path };
    flock $lock_fh, LOCK_EX or die "Could not lock $lock_path: $!";
    return $archive_path if -e $archive_path;
    log_info "Creating archive for job $job_id (category: $category) at $archive_path";
    # Archive::Zip does not keep all member data in memory. When using addFile or
    # addTree, it only remembers the filenames. writeToFileNamed then streams
    # the content from the original files to the output zip.
    my $zip = Archive::Zip->new();
    my $res_dir = $job->result_dir;

    if ($res_dir && -d $res_dir) {
        if ($category eq 'all') {
            log_debug "Adding results from $res_dir to archive";
            $zip->addTree($res_dir, 'testresults/');
        }
        elsif ($category eq 'resultfiles') {
            for my $file (@{$job->test_resultfile_list}) {
                my $full_path = path($res_dir)->child($file);
                $zip->addFile($full_path->to_string, "testresults/$file") if -e $full_path;
            }
        }
        elsif ($category eq 'ulogs') {
            my $ulogs_dir = path($res_dir)->child('ulogs');
            for my $file (@{$job->test_uploadlog_list}) {
                my $full_path = $ulogs_dir->child($file);
                $zip->addFile($full_path->to_string, "testresults/ulogs/$file") if -e $full_path;
            }
        }
    }

    if ($category eq 'all' || $category eq 'assets') {
        my $assets = $job->jobs_assets;
        while (my $ja = $assets->next) {
            my $asset = $ja->asset;
            my $disk_file = $asset->disk_file;
            next unless $disk_file && -e $disk_file;
            log_debug 'Adding asset ' . $asset->name . ' to archive';
            my $zip_path = $asset->type . '/' . $asset->name;
            if (-d $disk_file) {
                $zip->addTree($disk_file, $zip_path . '/');
            }
            else {
                $zip->addFile($disk_file, $zip_path);
            }
        }
    }

    cleanup_cache();
    my $temp_path = $cache_dir->child($archive_name . '.tmp.' . random_hex(8));
    # the archive is only served once it has been renamed, so a partial file must never survive
    my $remove_temp_guard = scope_guard sub () { $temp_path->remove if -e $temp_path };
    my $status = $zip->writeToFileNamed($temp_path->to_string);
    unless ($status == AZ_OK) {
        log_error "Failed to write archive for job $job_id to $temp_path: $status";
        die "Failed to create archive: $status";
    }
    rename $temp_path->to_string, $archive_path->to_string
      or die "Could not rename $temp_path to $archive_path: $!";
    return $archive_path;
}

sub is_cache_limit_exceeded ($current_size, $available, $total) {
    return $current_size > get_cache_limit() || ($available / $total * 100) < get_min_free_percentage();
}

sub _cache_file_regex () {
    my $category_regex = join '|', VALID_CATEGORIES;
    return qr/^job_\d+(?:_(?:$category_regex))?\.zip(?:\.tmp\.[0-9A-Fa-f]+|\.lock)?$/;
}

sub _cache_files ($cache_dir) {
    return $cache_dir->list->grep(sub { $_->basename =~ _cache_file_regex() });
}

sub _archive_name_of ($file) {
    my ($archive_name) = $file->basename =~ /^(.+\.zip)/;
    return $archive_name;
}

sub _is_stale ($file, $now) {
    return $file->stat->mtime < $now - STALE_ARCHIVE_AGE_SECONDS;
}

sub _lock_is_held ($lock_path) {
    return 0 unless -e $lock_path;
    my $held = 0;
    try {
        my $fh = $lock_path->open('<');
        $held = !flock $fh, LOCK_EX | LOCK_NB;
        close $fh;
    }
    catch ($e) { $held = 1 }    # uncoverable statement
    return $held;
}

sub _remove_stale_files ($cache_dir, $files, $now) {
    my @temp_files = grep { $_->basename =~ /\.tmp\./ } @$files;
    for my $file (@temp_files) {
        next unless _is_stale($file, $now);
        next if _lock_is_held($cache_dir->child(_archive_name_of($file) . '.lock'));
        log_info 'Removing stale temporary archive ' . $file;
        $file->remove;
    }

    my %present = map { $_->basename => 1 } $cache_dir->list->each;
    for my $file (grep { $_->basename =~ /\.lock$/ } @$files) {
        my $archive_name = _archive_name_of($file);
        next unless _is_stale($file, $now);
        # a creation creates its lock before its temporary file, so an archive name without both is orphaned
        next if $present{$archive_name} || grep { /^\Q$archive_name\E\.tmp\./ } keys %present;
        next if _lock_is_held($file);
        log_info 'Removing stale archive cache lock ' . $file;
        $file->remove;
    }
}

sub cleanup_cache () {
    my $cache_dir = path(archive_cache_dir());
    return unless -d $cache_dir;
    try { _perform_cache_cleanup($cache_dir) }
    catch ($e) { log_error "Failed to cleanup archive cache: $e" }    # uncoverable statement
}

sub _perform_cache_cleanup ($cache_dir) {
    my ($available, $total) = check_df($cache_dir->to_string);
    my $now = time;
    my $files = _cache_files($cache_dir);
    _remove_stale_files($cache_dir, $files, $now);

    my $entries = _cache_files($cache_dir)->map(
        sub {
            my $stat = $_->stat;
            {path => $_, mtime => $stat->mtime, size => $stat->size};
        });
    my $current_cache_size = 0;
    $entries->each(sub ($item, @) { $current_cache_size += $item->{size} });
    my $archives = $entries->grep(sub { $_->{path}->basename =~ /\.zip$/ })->sort(sub { $a->{mtime} <=> $b->{mtime} });

    return unless is_cache_limit_exceeded($current_cache_size, $available, $total);
    log_info 'Archive cache exceeds limits (size: '
      . human_readable_size($current_cache_size)
      . '), cleaning up oldest archives';
    my $target_size = get_cache_limit() * (get_watermark_percentage() / 100);
    while ($current_cache_size > $target_size && (my $oldest = shift @$archives)) {
        log_info 'Removing old archive ' . $oldest->{path};
        $oldest->{path}->remove;
        $current_cache_size -= $oldest->{size};
    }
}

1;
