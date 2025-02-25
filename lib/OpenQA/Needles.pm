# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Needles;
use Mojo::Base -strict, -signatures;

use Exporter qw(import);
use File::Basename;
use File::Spec;
use File::Spec::Functions qw(catdir);
use OpenQA::Git;
use OpenQA::Log qw(log_error);
use OpenQA::Utils qw(prjdir sharedir);
use Mojo::File qw(path);

our @EXPORT = qw(temp_dir is_in_temp_dir needle_temp_dir locate_needle _locate_needle_for_ref);

my $tmp_dir = prjdir() . '/webui/cache/needle-refs';

sub temp_dir () { $tmp_dir }

sub is_in_temp_dir ($file_path) { index($file_path, $tmp_dir) == 0 }

sub needle_temp_dir ($dir, $ref) { path($tmp_dir, basename(dirname($dir)), $ref, 'needles') }

sub _locate_needle_for_ref ($relative_needle_path, $needles_dir, $needles_ref) {
    return undef unless defined $needles_ref;
    my $temp_needles_dir = needle_temp_dir($needles_dir, $needles_ref);
    my $subdir = dirname($relative_needle_path);
    path($temp_needles_dir, $subdir)->make_path if File::Spec->splitdir($relative_needle_path) > 1;
    my $git = OpenQA::Git->new(dir => $needles_dir);
    my $temp_json_path = "$temp_needles_dir/$relative_needle_path";
    my $basename = basename($relative_needle_path, '.json');
    my $relative_png_path = "$subdir/$basename.png";
    my $temp_png_path = "$temp_needles_dir/$relative_png_path";
    my $error = $git->cache_ref($needles_ref, $relative_needle_path, $temp_json_path)
      // $git->cache_ref($needles_ref, $relative_png_path, $temp_png_path);
    return $temp_json_path unless defined $error;
    log_error "An error occurred when looking for ref '$needles_ref' of '$relative_needle_path': $error";
    return undef;
}

sub locate_needle ($relative_needle_path, $needles_dir, $needles_ref = undef) {
    my $location_for_ref = _locate_needle_for_ref($relative_needle_path, $needles_dir, $needles_ref);
    return $location_for_ref if defined $location_for_ref;
    my $absolute_filename = catdir($needles_dir, $relative_needle_path);
    my $needle_exists = -f $absolute_filename;
    if (!$needle_exists) {
        $absolute_filename = catdir(sharedir(), $relative_needle_path);
        $needle_exists = -f $absolute_filename;
    }
    return $absolute_filename if $needle_exists;
    log_error "Needle file $relative_needle_path not found within $needles_dir.";
    return undef;
}
