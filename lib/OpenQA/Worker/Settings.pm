# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Worker::Settings;
use Mojo::Base -base, -signatures;

use Mojo::URL;
use Mojo::Util 'trim';
use Config::IniFiles;
use Time::Seconds;
use OpenQA::Log 'setup_log';
use OpenQA::Utils 'is_host_local';
use Net::Domain 'hostfqdn';

has 'global_settings';
has 'webui_hosts';
has 'webui_host_specific_settings';

use constant VNCPORT_OFFSET => $ENV{VNCPORT_OFFSET} // 90;

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

    # read settings from config
    my %global_settings;
    _read_section($cfg, 'global', \%global_settings);
    _read_section($cfg, $instance_number, \%global_settings);
    _read_section($cfg, "class:$_", \%global_settings) for split(',', $global_settings{WORKER_CLASS} // '');

    # read global settings from environment variables
    for my $var (qw(LOG_DIR TERMINATE_AFTER_JOBS_DONE)) {
        $global_settings{$var} = $ENV{"OPENQA_WORKER_$var"} if ($ENV{"OPENQA_WORKER_$var"} // '') ne '';
    }

    # read global settings specified via CLI arguments
    $global_settings{LOG_LEVEL} = 'debug' if $cli_options->{verbose};

    # determine web UI host and settings specific to it
    my %webui_host_specific_settings;
    my @hosts = split(' ', $cli_options->{host} || $global_settings{HOST} || 'localhost');
    delete $global_settings{HOST};
    _read_section($cfg, $_, $webui_host_specific_settings{$_} = {}) for @hosts;

    # Select sensible system CPU load15 threshold to prevent system overload
    # based on experiences with system stability so far
    $global_settings{CRITICAL_LOAD_AVG_THRESHOLD} //= 40;

    # set some environment variables
    # TODO: This should be sent to the scheduler to be included in the worker's table.
    if (defined $instance_number) {
        $ENV{QEMUPORT} = $instance_number * 10 + 20002;
        $ENV{VNC} = $instance_number + VNCPORT_OFFSET;
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

sub _read_section ($cfg, $section, $out) {
    return undef unless $cfg && $cfg->SectionExists($section);
    $out->{uc $_} = trim $cfg->val($section, $_) for $cfg->Parameters($section);
}

sub auto_detect_worker_address ($self, $fallback = undef) {
    my $global_settings = $self->global_settings;
    my $current_address = $global_settings->{WORKER_HOSTNAME};

    # allow overriding WORKER_HOSTNAME explicitly; no validation is done in this case
    return 1 if defined $current_address && !$self->{_worker_address_auto_detected};

    # assign "localhost" as WORKER_HOSTNAME so entirely local setups work out of the box
    if ($self->is_local_worker) {
        $global_settings->{WORKER_HOSTNAME} = 'localhost';
        return 1;
    }

    # do auto-detection which is considered successful if hostfqdn() returns something with a dot in it
    $self->{_worker_address_auto_detected} = 1;
    my $worker_address = hostfqdn() // $fallback;
    $global_settings->{WORKER_HOSTNAME} = $worker_address if defined $worker_address;
    return defined $worker_address && index($worker_address, '.') >= 0;
}

sub apply_to_app ($self, $app) {
    my $global_settings = $self->global_settings;
    $app->log_dir($global_settings->{LOG_DIR});
    $app->level($global_settings->{LOG_LEVEL}) if $global_settings->{LOG_LEVEL};
    setup_log($app, undef, $app->log_dir, $app->level);
}

sub file_path ($self) { $self->{_file_path} }

sub parse_errors ($self) { $self->{_parse_errors} }

sub is_local_worker ($self) {
    my $local = $self->{_local};
    return $local if defined $local;
    for my $host_url (@{$self->webui_hosts}) {
        return $self->{_local} = 0 unless is_host_local(Mojo::URL->new($host_url)->host // $host_url);
    }
    return $self->{_local} = 1;
}

sub has_class ($self, $worker_class) {
    my $c = $self->{_worker_classes} //= {map { $_ => 1 } split(',', $self->global_settings->{WORKER_CLASS} // '')};
    return exists $c->{$worker_class};
}

1;
