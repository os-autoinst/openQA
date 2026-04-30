# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Config;
use Mojo::Base -strict, -signatures;

use Config::IniFiles;
use Exporter qw(import);
use OpenQA::Log qw(log_info log_warning);
use Mojo::File qw(path);
use Feature::Compat::Try;

our @EXPORT
  = qw(config_dir_within_app_home lookup_config_files parse_config_files parse_config_files_as_hash parse_worker_class_auto_assignment);

sub _config_dirs ($config_dir_within_home) {
    return [[$ENV{OPENQA_CONFIG} // ()], [$config_dir_within_home // ()], ['/etc/openqa', '/usr/etc/openqa']];
}

sub config_dir_within_app_home ($app) { $app->child('etc', 'openqa') }

sub _parse_auto_assignment_entry ($entry) {
    my ($pattern_str, $class) = split /\s*->\s*/, $entry, 2;
    if (!defined $class) {
        log_warning("Missing delimiter ' -> ' in worker_class_auto_assignment: $entry");
        return ();
    }
    my $pattern_regex;
    try { $pattern_regex = qr/$pattern_str/ }
    catch ($e) {
        log_warning("Invalid regex pattern in worker_class_auto_assignment: $pattern_str");
        return ();
    }
    return {pattern => $pattern_regex, class => $class};
}

sub parse_worker_class_auto_assignment ($config) {
    return $config->{_worker_class_auto_assignment_rules} if $config->{_worker_class_auto_assignment_rules};

    my $section = $config->{worker_class_auto_assignment} or return [];
    my $entries = $section->{add_worker_class_if_missing} or return [];
    $entries = [$entries] unless ref $entries eq 'ARRAY';

    my $rules = [map { _parse_auto_assignment_entry($_) } grep { $_ } @$entries];
    $config->{_worker_class_auto_assignment_rules} = $rules;
    return $rules;
}

sub lookup_config_files ($config_dir_within_home, $name, $silent = 0) {
    my $config_name;
    my @config_file_paths;
    for my $paths (@{_config_dirs($config_dir_within_home)}) {
        for my $path (@$paths) {
            my $config_path = path($path);
            my $main_config_file = $config_path->child($name);
            my $extension = $main_config_file->extname;
            my $has_main_config = -r $main_config_file;
            $config_name //= $main_config_file->basename(".$extension");
            push @config_file_paths, $main_config_file if $has_main_config;
            push @config_file_paths, @{$config_path->child("$name.d")->list->grep(qr/\.$extension$/)->sort};
            last if $has_main_config;
        }
        if (@config_file_paths) {
            log_info("Reading $config_name config from: @config_file_paths") unless $silent;
            last;
        }
    }
    return \@config_file_paths;
}

sub parse_config_files ($config_file_paths) {
    my $config_file;
    for my $config_file_path (@$config_file_paths) {
        my @import_args = $config_file ? (-import => $config_file) : ();
        my $next_config_file = Config::IniFiles->new(-file => $config_file_path->to_string, @import_args);
        $config_file = $next_config_file if $next_config_file;
    }
    return $config_file;
}

sub parse_config_files_as_hash ($config_file_paths) {
    return undef unless my $config_file = parse_config_files($config_file_paths);
    my %config_hash;
    tie %config_hash, 'Config::IniFiles', (-import => $config_file);
    return \%config_hash;
}

1;
