# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Worker::Settings;
use Mojo::Base -base, -signatures;

use Mojo::Util 'trim';
use Config::IniFiles;
use Time::Seconds;
use OpenQA::Log 'setup_log';

has 'global_settings';
has 'webui_hosts';
has 'webui_host_specific_settings';

sub new ($class, $instance_number = undef, $cli_options = {}) {
    my $settings_file = ($ENV{OPENQA_CONFIG} || '/etc/openqa') . '/workers.ini';
    my $cfg;
    my @parse_errors;
    if (-e $settings_file) {
        $cfg = Config::IniFiles->new(-file => $settings_file);
        push(@parse_errors, @Config::IniFiles::errors) unless $cfg;
    }
    else {
        push(@parse_errors, "Config file not found at '$settings_file'.");
        $settings_file = undef;
    }

    # read global settings from config
    my %global_settings;
    for my $section ('global', $instance_number) {
        if ($cfg && $cfg->SectionExists($section)) {
            for my $set ($cfg->Parameters($section)) {
                $global_settings{uc $set} = trim $cfg->val($section, $set);
            }
        }
    }

    # read global settings from environment variables
    for my $var (qw(LOG_DIR TERMINATE_AFTER_JOBS_DONE)) {
        $global_settings{$var} = $ENV{"OPENQA_WORKER_$var"} if ($ENV{"OPENQA_WORKER_$var"} // '') ne '';
    }

    # read global settings specified via CLI arguments
    $global_settings{LOG_LEVEL} = 'debug' if $cli_options->{verbose};

    # determine web UI host
    my $webui_host = $cli_options->{host} || $global_settings{HOST} || 'localhost';
    delete $global_settings{HOST};

    # determine web UI host specific settings
    my %webui_host_specific_settings;
    my @hosts = split(' ', $webui_host);
    for my $section (@hosts) {
        if ($cfg && $cfg->SectionExists($section)) {
            for my $set ($cfg->Parameters($section)) {
                $webui_host_specific_settings{$section}->{uc $set} = trim $cfg->val($section, $set);
            }
        }
        else {
            $webui_host_specific_settings{$section} = {};
        }
    }

    # set some environment variables
    # TODO: This should be sent to the scheduler to be included in the worker's table.
    if (defined $instance_number) {
        $ENV{QEMUPORT} = $instance_number * 10 + 20002;
        $ENV{VNC} = $instance_number + 90;
    }

    # assign default retry-delay for web UI connection
    $global_settings{RETRY_DELAY} //= 5;
    $global_settings{RETRY_DELAY_IF_WEBUI_BUSY} //= ONE_MINUTE;

    my $self = $class->SUPER::new(
        global_settings => \%global_settings,
        webui_hosts => \@hosts,
        webui_host_specific_settings => \%webui_host_specific_settings,
    );
    $self->{_file_path} = $settings_file;
    $self->{_parse_errors} = \@parse_errors;
    return $self;
}

sub apply_to_app ($self, $app) {
    my $global_settings = $self->global_settings;
    $app->log_dir($global_settings->{LOG_DIR});
    $app->level($global_settings->{LOG_LEVEL}) if $global_settings->{LOG_LEVEL};
    setup_log($app, undef, $app->log_dir, $app->level);
}

sub file_path ($self) { $self->{_file_path} }

sub parse_errors ($self) { $self->{_parse_errors} }

1;
