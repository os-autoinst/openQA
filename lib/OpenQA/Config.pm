# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Config;
use Mojo::Base -strict, -signatures;

use Config::IniFiles;
use Exporter qw(import);
use OpenQA::Log qw(log_info);
use Mojo::File qw(path);

our @EXPORT = qw(lookup_config_files parse_config_files parse_config_files_as_hash);

sub lookup_config_files ($home, $name, $silent = 0) {
    my @config_file_paths;
    for my $path ($ENV{OPENQA_CONFIG}, $home, '/etc/openqa', '/usr/etc/openqa') {
        next unless defined $path;
        my $config_path = path($path);
        my $main_config_file = $config_path->child($name);
        my $extension = $main_config_file->extname;
        my $config_name = $main_config_file->basename(".$extension");
        push @config_file_paths, $main_config_file if -r $main_config_file;
        push @config_file_paths, @{$config_path->child("$name.d")->list->grep(qr/\.$extension$/)->sort};
        if (@config_file_paths) {
            log_info "Reading $config_name config from: @config_file_paths" unless $silent;
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
    my %config_hash;
    return \%config_hash unless my $config_file = parse_config_files($config_file_paths);
    tie %config_hash, 'Config::IniFiles', (-import => $config_file);
    return \%config_hash;
}

1;
