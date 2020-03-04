# Copyright (C) 2019 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::Worker::Settings;
use Mojo::Base -base;

use Mojo::Util 'trim';
use Config::IniFiles;
use OpenQA::Setup;

has 'global_settings';
has 'webui_hosts';
has 'webui_host_specific_settings';

sub new {
    my ($class, $instance_number, $cli_options) = @_;
    $cli_options //= {};

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
    $global_settings{LOG_DIR} = $ENV{OPENQA_WORKER_LOGDIR} if $ENV{OPENQA_WORKER_LOGDIR};

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
        $ENV{VNC}      = $instance_number + 90;
    }

    # assign default retry-delay for web UI connection
    $global_settings{RETRY_DELAY}               //= 5;
    $global_settings{RETRY_DELAY_IF_WEBUI_BUSY} //= 60;

    my $self = $class->SUPER::new(
        global_settings              => \%global_settings,
        webui_hosts                  => \@hosts,
        webui_host_specific_settings => \%webui_host_specific_settings,
    );
    $self->{_file_path}    = $settings_file;
    $self->{_parse_errors} = \@parse_errors;
    return $self;
}

sub apply_to_app {
    my ($self, $app) = @_;

    my $global_settings = $self->global_settings;
    $app->log_dir($global_settings->{LOG_DIR});
    $app->level($global_settings->{LOG_LEVEL}) if $global_settings->{LOG_LEVEL};
    OpenQA::Setup::setup_log($app);
}

sub file_path { shift->{_file_path} }

sub parse_errors { shift->{_parse_errors} }

1;
