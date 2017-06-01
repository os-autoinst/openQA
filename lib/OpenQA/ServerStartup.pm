# Copyright (C) 2015-2016 SUSE LLC
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

# This package contains shared functions between WebAPI and WebSockets
package OpenQA::ServerStartup;

use strict;
use warnings;
use Config::IniFiles;
use db_profiler;
use db_helpers;
use OpenQA::Utils;
use Mojo::File 'path';

sub read_config {
    my $app = shift;

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
    my $cfg;
    my $cfgpath = $ENV{OPENQA_CONFIG} ? path($ENV{OPENQA_CONFIG}) : $app->home->child("etc", "openqa");
    my $cfgfile = $cfgpath->child('openqa.ini');

    if (-e $cfgfile) {
        $cfg = Config::IniFiles->new(-file => $cfgfile->to_string) || undef;
    }
    else {
        $app->log->warn("No configuration file supplied, will fallback to default configuration");
    }

    for my $section (sort keys %defaults) {
        for my $k (sort keys %{$defaults{$section}}) {
            my $v = $cfg && $cfg->val($section, $k);
            $v //=
              exists $mode_defaults{$app->mode}{$section}->{$k} ?
              $mode_defaults{$app->mode}{$section}->{$k}
              : $defaults{$section}->{$k};
            $app->config->{$section}->{$k} = $v if defined $v;
        }
    }
    $app->config->{global}->{recognized_referers} = [split(/ /, $app->config->{global}->{recognized_referers})];
    $app->config->{_openid_secret} = db_helpers::rndstr(16);
    $app->config->{auth}->{method} =~ s/\s//g;
}

sub setup_logging {
    my ($app) = @_;

    my $config = $app->config;
    my $logfile = $ENV{OPENQA_LOGFILE} || $config->{logging}->{file};

    if ($logfile) {
        $app->log->path($logfile);
        $app->log->format(
            sub {
                my ($time, $level, @lines) = @_;
                return '[' . localtime($time) . "] [" . $app->log_name . ":$level] " . join "\n", @lines, '';
            });
    }
    else {
        $app->log->format(
            sub {
                my (undef, $level, @lines) = @_;
                return '[' . $app->log_name . ":$level] " . join "\n", @lines, '';
            });
    }

    if ($logfile && $config->{logging}->{level}) {
        $app->log->level($config->{logging}->{level});
    }
    if ($ENV{OPENQA_SQL_DEBUG} // $config->{logging}->{sql_debug} // 'false' eq 'true') {
        # avoid enabling the SQL debug unless we really want to see it
        # it's rather expensive
        db_profiler::enable_sql_debugging($app);
    }

    $OpenQA::Utils::app = $app;
}

1;
