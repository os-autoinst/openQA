# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Needles;
use Mojo::Base -strict, -signatures;

use Exporter qw(import);
use File::Basename;
use File::Spec;
use OpenQA::App;
use OpenQA::Git;
use OpenQA::Log qw(log_error);
use OpenQA::Utils qw(prjdir sharedir);
use Mojo::File qw(path);

our @EXPORT_OK = qw(temp_dir is_in_temp_dir needle_temp_dir locate_needle _locate_needle_for_ref);

my $tmp_dir = prjdir() . '/webui/cache/needle-refs';

sub temp_dir () { $tmp_dir }

sub is_in_temp_dir ($file_path) {
    my $abs_tmpdir = File::Spec->rel2abs($tmp_dir);
    $file_path = File::Spec->rel2abs($file_path);
    index($file_path, $abs_tmpdir) == 0;
}

sub needle_temp_dir ($dir, $ref) { path($tmp_dir, basename(dirname($dir)), $ref, 'needles') }

sub _locate_needle_for_ref ($relative_needle_path, $needles_dir, $needles_ref, $needle_url) {
    # checkout needle from git - return absolute path to json file on success and undef on error
    return undef unless defined $needles_ref;
    my $app = OpenQA::App->singleton;
    my $allow_arbitrary_url_fetch = $app->config->{'scm git'}->{allow_arbitrary_url_fetch} eq 'yes';
    my $temp_needles_dir = needle_temp_dir($needles_dir, $needles_ref);
    my $subdir = dirname($relative_needle_path);
    my $git = OpenQA::Git->new(app => $app, dir => $needles_dir);
    my $temp_json_path = "$temp_needles_dir/$relative_needle_path";
    my $basename = basename($relative_needle_path, '.json');
    my $relative_png_path = "$subdir/$basename.png";
    my $temp_png_path = "$temp_needles_dir/$relative_png_path";
    my $error
      = $git->cache_ref($needles_ref, $needle_url, $relative_needle_path, $temp_json_path, $allow_arbitrary_url_fetch)
      // $git->cache_ref($needles_ref, $needle_url, $relative_png_path, $temp_png_path, $allow_arbitrary_url_fetch);
    log_error "An error occurred when looking for ref '$needles_ref' of '$relative_needle_path': $error"
      if defined $error;
    return (defined $error) ? undef : $temp_json_path;
}

sub locate_needle ($relative_needle_path, $needles_dir, $needles_ref = undef, $needle_url = undef) {
    # return absolute path to needle - if possible via tmp checkout of needle from git at requested ref
    # else just the current needle in the <$needles_dir>
    # if that fails as well return undef
    my $location_for_ref = _locate_needle_for_ref($relative_needle_path, $needles_dir, $needles_ref, $needle_url);
    return $location_for_ref if defined $location_for_ref;
    my $absolute_filename = path($needles_dir, $relative_needle_path);
    my $needle_exists = -f $absolute_filename;
    if (!$needle_exists) {
        $absolute_filename = path(sharedir(), $relative_needle_path);
        $needle_exists = -f $absolute_filename;
    }
    return $absolute_filename if $needle_exists;
    log_error "Needle file $relative_needle_path not found within $needles_dir.";
    return undef;
}

1;
