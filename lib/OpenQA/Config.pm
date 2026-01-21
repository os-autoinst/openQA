# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Config;
use Mojo::Base -strict, -signatures;

use Config::IniFiles;
use Exporter qw(import);
use OpenQA::Log qw(log_info);
use Mojo::File qw(path);
use File::Copy qw(copy);
use YAML::PP;

our @EXPORT = qw(
  config_dir_within_app_home lookup_config_files parse_config_files parse_config_files_as_hash
  show_config write_config
);

sub _config_dirs ($config_dir_within_home) {
    return [[$ENV{OPENQA_CONFIG} // ()], [$config_dir_within_home // ()], ['/etc/openqa', '/usr/etc/openqa']];
}

sub config_dir_within_app_home ($app) { $app->child('etc', 'openqa') }

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
    return undef unless my $config_file = parse_config_files($config_file_paths);
    my %config_hash;
    tie %config_hash, 'Config::IniFiles', (-import => $config_file);
    return \%config_hash;
}

sub show_config ($file, $params) {
    my $conf = Config::IniFiles->new(-file => $file);
    my ($section, $param, $val) = @$params;
    unless (defined $section) {
        my @sections = $conf->Sections;
        return YAML::PP::Dump({Sections => \@sections});
    }
    unless (defined $param) {
        my @keys = $conf->Parameters($section);
        return YAML::PP::Dump(
            {
                "Parameters($section)" => {
                    map { $_ => $conf->val($section, $_) } @keys
                }});
    }
    unless (defined $val) {
        $val = $conf->val($section, $param);
        return $val;
    }
    return;
}

sub write_config ($file, $params, $backup = 0) {
    my $conf = Config::IniFiles->new(-file => $file);
    my ($section, $param, $val) = @$params;
    if (!defined $section || !defined $param || !defined $val) {
        warn "You need to pass section, parameter and value\n";
        return 1;
    }
    $conf->newval($section, $param, $val);
    if (my $bak = $backup) {
        copy $file, "$file.$bak";
    }
    if (ref $file) {
        # we have something other than just a filename; just print
        $conf->OutputConfig;
    }
    else {
        $conf->RewriteConfig();
    }
}


1;
