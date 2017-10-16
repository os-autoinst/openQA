# Copyright (C) 2016 SUSE LLC
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

package OpenQA::FakeApp;
use Mojo::Log;
use Mojo::Home;
use strict;
use warnings;
#use Mojo::Base -base;
use Mojo::Base 'Mojolicious';
use Sys::Hostname;
use File::Spec::Functions 'catfile';
use Mojo::File 'path';
use Config::IniFiles;
use db_profiler;
use db_helpers;
use Data::Dumper;

has config => sub { shift()->read_config(); };

has log => sub { shift()->setup_log;  };

has home => sub { Mojo::Home->new($ENV{MOJO_HOME} || '/') };

has mode => 'production';

has log_name => 'scheduler';

has level => sub {shift()->config->{level} || 'debug'};

has instance => undef;

has log_dir => undef;

has schema => sub { OpenQA::Schema::connect_db() };

sub setup_log {
    my ($self) = @_;
    my $logfile = $ENV{OPENQA_LOGFILE} || $self->config->{logging}->{file};
    my $log;
    if($logfile && $self->log_dir) {
        my $logfile = catfile($self->log_dir, $logfile);
        $log =  Mojo::Log->new(handle => \*STDOUT, level=> $self->level);
    } elsif($logfile) {
        $log = Mojo::Log->new(handle => path($logfile)->open('>>'), level=> $self->level);
    } elsif($self->log_dir) {
        my $logfile
            = catfile($self->log_dir, hostname() . (defined $self->instance ? "-${\$self->instance}" : '') . ".log");
        $log = Mojo::Log->new(handle => path($logfile)->open('>>'), level=> $self->level);
    } else {
        $log = Mojo::Log->new(handle => \*STDOUT, level=> $self->level);
    }

    $log->format(
        sub {
            my ($time, $level, @lines) = @_;
            return '[' . localtime($time) . "] [${\$self->log_name}:$level] " . join "\n", @lines, '';
        });

    $log->level($self->level);
    return $log;
}

# sub setup_log {
#     my ($self) = @_;
#     if ($self->log_dir) {
#         # So each worker from each host get it's own log (as the folder can be shared). Hopefully the machine hostname
#         # is already sanitized. Otherwise we need to check
#         my $logfile
#           = catfile($self->log_dir, hostname() . (defined $self->instance ? "-${\$self->instance}" : '') . ".log");

#         $self->log->handle(path($logfile)->open('>>'));

#         $self->log->path($logfile);
#     }

#     $self->log->format(
#         sub {
#             my ($time, $level, @lines) = @_;
#             return '[' . localtime($time) . "] [${\$self->log_name}:$level] " . join "\n", @lines, '';
#         });

#     $self->log->level($self->level);
# }


sub emit_event {
    my ($self, $event, $data) = @_;
    # nothing to see here, move along
}

sub read_config {
    my $self = shift;

    my %defaults = (
        global => {
            appname             => 'openQA',
            base_url            => undef,
            branding            => 'openSUSE',
            download_domains    => undef,
            suse_mirror         => undef,
            scm                 => undef,
            hsts                => 365,
            audit_enabled       => 1,
            max_rss_limit       => 0,
            profiling_enabled   => 0,
            plugins             => undef,
            hide_asset_types    => 'repo',
            recognized_referers => ''
        },
        auth => {
            method => 'OpenID',
        },
        'scm git' => {
            do_push => 'no',
        },
        logging => {
            level     => undef,
            file      => undef,
            sql_debug => undef,
        },
        openid => {
            provider  => 'https://www.opensuse.org/openid/user/',
            httpsonly => 1,
        },
        hypnotoad => {
            listen => ['http://localhost:9526/'],
            proxy  => 1,
        },
        audit => {
            blacklist => '',
        },
        amqp => {
            reconnect_timeout => 5,
            url               => 'amqp://guest:guest@localhost:5672/',
            exchange          => 'pubsub',
            topic_prefix      => 'suse',
        },
    );

    # in development mode we use fake auth and log to stderr
    my %mode_defaults = (
        development => {
            auth => {
                method => 'Fake',
            },
            logging => {
                file  => undef,
                level => 'debug',
            },
        },
        test => {
            auth => {
                method => 'Fake',
            },
            logging => {
                file  => undef,
                level => 'debug',
            },
        });

    # Mojo's built in config plugins suck. JSON for example does not
    # support comments
    my $config={};
    my $cfg;
    my $cfgpath = $ENV{OPENQA_CONFIG} ? path($ENV{OPENQA_CONFIG}) : $self->home->child("etc", "openqa");
    my $cfgfile = $cfgpath->child('openqa.ini');

    if (-e $cfgfile) {
        $cfg = Config::IniFiles->new(-file => $cfgfile->to_string) || undef;
        $config->{ini_config} = $cfg;
    }
    else {
        $self->log->warn("No configuration file supplied, will fallback to default configuration");
    }

    for my $section (sort keys %defaults) {
        for my $k (sort keys %{$defaults{$section}}) {
            my $v = $cfg && $cfg->val($section, $k);
            $v //=
              exists $mode_defaults{$self->mode}{$section}->{$k} ?
              $mode_defaults{$self->mode}{$section}->{$k}
              : $defaults{$section}->{$k};
            $config->{$section}->{$k} = $v if defined $v;
        }
    }
    $config->{global}->{recognized_referers} = [split(/ /, $config->{global}->{recognized_referers})];
    $config->{_openid_secret} = db_helpers::rndstr(16);
    $config->{auth}->{method} =~ s/\s//g;

    return $config;
}


# Update config definition from plugin requests
sub update_config {
    my ($app, @namespaces) = @_;
    return unless exists $app->config->{ini_config};

    # Filter out what plugins are loaded from the used namespaces
    foreach my $plugin (loaded_plugins(@namespaces)) {

        # We take config only if the plugin has the method declared
        next unless ($plugin->can("configuration_fields"));

        # If it is a Mojo::Base class, it requires to be instantiated
        # because the attributes are not populated until creation.
        my $fields
          = UNIVERSAL::isa($plugin, "Mojo::Base") ?
          do { $plugin->new->configuration_fields() }
          : $plugin->configuration_fields();

        # We expect just hashrefs
        next unless (ref($fields) eq "HASH");

        # Walk the hash with the plugin returns that needs to be fetched
        # by our Ini file parser and fill config from it
        hashwalker $fields => sub {
            my ($key, undef, $keys) = @_;
            my $v = $app->config->{ini_config}->val(@$keys[0], $key);
            $app->config->{@$keys[0]}->{$key} = $v if defined $v;
        };
    }
}

1;
