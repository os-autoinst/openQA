# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Archive;
use Mojo::Base -strict, -signatures;

use Archive::Zip qw(:ERROR_CODES :CONSTANTS);
use Mojo::File 'path';
use OpenQA::Utils qw(resultdir assetdir check_df locate_asset human_readable_size random_hex);
use OpenQA::Log qw(log_info log_error log_debug);
use OpenQA::App;
use File::Basename;
use Feature::Compat::Try;
use Fcntl qw(:flock);

sub archive_cache_dir () {
    return $ENV{OPENQA_JOB_DETAILS_ARCHIVE_CACHE_DIR} if $ENV{OPENQA_JOB_DETAILS_ARCHIVE_CACHE_DIR};
    my $config = OpenQA::App->singleton->config->{job_details_archive};
    return $config->{job_details_archive_cache_dir} if $config->{job_details_archive_cache_dir};
    return path(OpenQA::Utils::prjdir(), 'cache', 'archives')->to_string;
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

sub create_job_archive ($job) {
    my $job_id = $job->id;
    my $cache_dir = path(archive_cache_dir());
    $cache_dir->make_path unless -d $cache_dir;
    my $archive_name = "job_$job_id.zip";
    my $archive_path = $cache_dir->child($archive_name);
    my $lock_path = $cache_dir->child("$archive_name.lock");
    open(my $lock_fh, '>', $lock_path->to_string) or die "Could not open lock file $lock_path: $!";
    flock($lock_fh, LOCK_EX) or die "Could not lock $lock_path: $!";
    if (-e $archive_path) {
        close($lock_fh);
        return $archive_path;
    }
    log_info("Creating archive for job $job_id at $archive_path");
    my $zip = Archive::Zip->new();
    if (my $res_dir = $job->result_dir) {
        log_debug("Adding results from $res_dir to archive");
        $zip->addTree($res_dir, 'testresults/') if -d $res_dir;
    }
    my $assets = $job->jobs_assets;
    while (my $ja = $assets->next) {
        my $asset = $ja->asset;
        my $disk_file = $asset->disk_file;
        if ($disk_file && -e $disk_file) {
            log_debug('Adding asset ' . $asset->name . ' to archive');
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
    my $status = $zip->writeToFileNamed($temp_path->to_string);
    unless ($status == AZ_OK) {
        $temp_path->remove if -e $temp_path;
        close($lock_fh);
        log_error("Failed to write archive for job $job_id to $temp_path: $status");
        die "Failed to create archive: $status";
    }
    rename($temp_path->to_string, $archive_path->to_string)
      or die "Could not rename $temp_path to $archive_path: $!";
    close($lock_fh);
    $lock_path->remove;
    return $archive_path;
}

sub is_cache_limit_exceeded ($current_size, $available, $total) {
    return 1 if $current_size > get_cache_limit();
    return 1 if ($available / $total * 100) < get_min_free_percentage();
    return 0;
}

sub cleanup_cache () {
    my $cache_dir = path(archive_cache_dir());
    return unless -d $cache_dir;
    try { _perform_cache_cleanup($cache_dir) }
    catch ($e) { log_error("Failed to cleanup archive cache: $e") }
}

sub _perform_cache_cleanup ($cache_dir) {
    my ($available, $total) = check_df($cache_dir->to_string);
    my $current_cache_size = 0;
    my @archives;
    $cache_dir->list->each(
        sub ($file, $num) {
            return unless $file->basename =~ /^job_\d+\.zip$/;
            my $stat = $file->stat;
            push @archives, {path => $file, mtime => $stat->mtime, size => $stat->size};
            $current_cache_size += $stat->size;
        });
    return unless is_cache_limit_exceeded($current_cache_size, $available, $total);
    log_info('Archive cache exceeds limits (size: '
          . human_readable_size($current_cache_size)
          . '), cleaning up oldest archives');
    @archives = sort { $a->{mtime} <=> $b->{mtime} } @archives;
    my $target_size = get_cache_limit() * (get_watermark_percentage() / 100);
    while ($current_cache_size > $target_size && @archives) {

        my $oldest = shift @archives;
        log_info('Removing old archive ' . $oldest->{path});
        $oldest->{path}->remove;
        $current_cache_size -= $oldest->{size};
    }
}

1;
