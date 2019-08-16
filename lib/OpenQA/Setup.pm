# Copyright (C) 2017 SUSE LLC
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

package OpenQA::Setup;
use Mojo::Base -base;

use Mojo::Home;
use Mojo::Log;
use Sys::Hostname;
use File::Spec::Functions 'catfile';
use Mojo::File 'path';
use Mojo::Util 'trim';
use Config::IniFiles;
use OpenQA::Schema::Profiler;
use OpenQA::Utils;
use OpenQA::Utils 'random_string';
use File::Path 'make_path';
use POSIX 'strftime';
use Time::HiRes 'gettimeofday';
use OpenQA::Schema::JobGroupDefaults;

has config => sub { {} };

has log => sub { Mojo::Log->new(handle => \*STDOUT, level => "info"); };

has home => sub { Mojo::Home->new($ENV{MOJO_HOME} || '/') };

has mode => 'production';

has 'log_name';

has 'level';

has 'instance';

has 'log_dir';

sub setup_log {
    my ($self) = @_;
    my ($logfile, $logdir, $level, $log);

    if ($self->isa('OpenQA::Setup')) {
        $logdir = $self->log_dir;
        $level  = $self->level;
        if ($logdir && !-e $logdir) {
            make_path($logdir);
        }
        elsif ($logdir && !-d $logdir) {
            die "Please point the logs to a valid folder!";
        }
    }
    else {
        $log = $self->log;
    }
    $level //= $self->config->{logging}->{level} // 'info';
    $logfile = $ENV{OPENQA_LOGFILE} || $self->config->{logging}->{file};

    if ($logfile && $logdir) {
        $logfile = catfile($logdir, $logfile);
        $log     = Mojo::Log->new(
            handle => path($logfile)->open('>>'),
            level  => $self->level,
            format => \&log_format_callback
        );
    }
    elsif ($logfile) {
        $log = Mojo::Log->new(
            handle => path($logfile)->open('>>'),
            level  => $level,
            format => \&log_format_callback
        );
    }
    elsif ($logdir) {
        # So each worker from each host get it's own log (as the folder can be shared). Hopefully the machine hostname
        # is already sanitized. Otherwise we need to check
        $logfile
          = catfile($logdir, hostname() . (defined $self->instance ? "-${\$self->instance}" : '') . ".log");
        $log = Mojo::Log->new(
            handle => path($logfile)->open('>>'),
            level  => $self->level,
            format => \&log_format_callback
        );
    }
    else {
        $log = Mojo::Log->new(
            handle => \*STDOUT,
            level  => $level,
            format => sub {
                my ($time, $level, @lines) = @_;
                return "[$level] " . join "\n", @lines, '';
            });
    }

    $self->log($log);
    if ($ENV{OPENQA_SQL_DEBUG} // $self->config->{logging}->{sql_debug} // 'false' eq 'true') {
        # avoid enabling the SQL debug unless we really want to see it
        # it's rather expensive
        OpenQA::Schema::Profiler->enable_sql_debugging;
    }

    $OpenQA::Utils::app = $self;
    return $log;
}

sub emit_event {
    my ($self, $event, $data) = @_;
    # nothing to see here, move along
}

sub read_config {
    my $app      = shift;
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
            monitoring_enabled  => 0,
            plugins             => undef,
            hide_asset_types    => 'repo',
            recognized_referers => '',
            changelog_file      => '/usr/share/openqa/public/Changelog',
        },
        auth => {
            method => 'OpenID',
        },
        'scm git' => {
            update_remote => '',
            update_branch => '',
            do_push       => 'no',
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
        'audit/storage_duration' => {
            startup     => undef,
            jobgroup    => undef,
            jobtemplate => undef,
            table       => undef,
            iso         => undef,
            user        => undef,
            asset       => undef,
            needle      => undef,
            other       => undef,
        },
        plugin_links => {
            operator => {},
            admin    => {}
        },
        amqp => {
            reconnect_timeout => 5,
            url               => 'amqp://guest:guest@localhost:5672/',
            exchange          => 'pubsub',
            topic_prefix      => 'suse',
        },
        obs_rsync => {
            home               => '',
            retry_interval     => 15,
            queue_limit        => 200,
            concurrency        => 2,
            project_status_url => '',
        },
        default_group_limits => {
            asset_size_limit                  => OpenQA::Schema::JobGroupDefaults::SIZE_LIMIT_GB,
            log_storage_duration              => OpenQA::Schema::JobGroupDefaults::KEEP_LOGS_IN_DAYS,
            important_log_storage_duration    => OpenQA::Schema::JobGroupDefaults::KEEP_IMPORTANT_LOGS_IN_DAYS,
            result_storage_duration           => OpenQA::Schema::JobGroupDefaults::KEEP_RESULTS_IN_DAYS,
            important_result_storage_duration => OpenQA::Schema::JobGroupDefaults::KEEP_IMPORTANT_RESULTS_IN_DAYS,
        },
        misc_limits => {
            untracked_assets_storage_duration => 14,
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
        $app->config->{ini_config} = $cfg;
    }
    else {
        $app->log->warn("No configuration file supplied, will fallback to default configuration");
    }

    for my $section (sort keys %defaults) {
        for my $k (sort keys %{$defaults{$section}}) {
            my $v = $cfg && $cfg->val($section, $k);
            $v //=
              exists $mode_defaults{$app->mode}{$section}->{$k}
              ? $mode_defaults{$app->mode}{$section}->{$k}
              : $defaults{$section}->{$k};
            $app->config->{$section}->{$k} = trim $v if defined $v;
        }
    }
    $app->config->{global}->{recognized_referers} = [split(/\s+/, $app->config->{global}->{recognized_referers})];
    $app->config->{_openid_secret} = random_string(16);
    $app->config->{auth}->{method} =~ s/\s//g;
}

# Update config definition from plugin requests
sub update_config {
    my ($config, @namespaces) = @_;
    return unless exists $config->{ini_config};

    # Filter out what plugins are loaded from the used namespaces
    foreach my $plugin (loaded_plugins(@namespaces)) {

        # We take config only if the plugin has the method declared
        next unless ($plugin->can("configuration_fields"));

        # If it is a Mojo::Base class, it requires to be instantiated
        # because the attributes are not populated until creation.
        my $fields
          = UNIVERSAL::isa($plugin, "Mojo::Base")
          ? do { $plugin->new->configuration_fields() }
          : $plugin->configuration_fields();

        # We expect just hashrefs
        next unless (ref($fields) eq "HASH");

        # Walk the hash with the plugin returns that needs to be fetched
        # by our Ini file parser and fill config from it
        hashwalker $fields => sub {
            my ($key, undef, $keys) = @_;
            my $v = $config->{ini_config}->val(@$keys[0], $key);
            $config->{@$keys[0]}->{$key} = $v if defined $v;
        };
    }
}

sub schema { OpenQA::Schema->singleton }

sub setup_app_defaults {
    my ($server) = @_;
    $server->defaults(appname         => $server->app->config->{global}->{appname});
    $server->defaults(current_version => detect_current_version($server->app->home));
}

sub setup_template_search_path {
    my ($server) = @_;
    unshift @{$server->renderer->paths}, '/etc/openqa/templates';
}

sub setup_plain_exception_handler {
    my ($server) = @_;

    $server->helper(
        'reply.exception' => sub {
            my ($c, $error) = @_;

            my $app = $c->app;
            $error = blessed $error && $error->isa('Mojo::Exception') ? $error : Mojo::Exception->new($error);
            $error = $error->inspect;
            $app->log->error($error);
            $error = 'internal error' if ($app->mode ne 'development');
            $c->render(text => $error, status => 500);
        });
}

sub setup_mojo_tmpdir {
    unless ($ENV{MOJO_TMPDIR}) {
        $ENV{MOJO_TMPDIR} = $OpenQA::Utils::assetdir . '/tmp';
        # Try to create tmpdir if it doesn't exist but don't die if failed to create
        if (!-e $ENV{MOJO_TMPDIR}) {
            eval { make_path($ENV{MOJO_TMPDIR}); };
            if ($@) {
                print STDERR "Can not create MOJO_TMPDIR : $@\n";
            }
        }
        delete $ENV{MOJO_TMPDIR} unless -w $ENV{MOJO_TMPDIR};
    }
}

sub load_plugins {
    my ($server, $monitoring_root_route) = @_;

    push @{$server->plugins->namespaces}, 'OpenQA::WebAPI::Plugin';

    foreach my $plugin (qw(Helpers CSRF REST HashedParams Gru YAMLRenderer)) {
        $server->plugin($plugin);
    }

    if ($server->config->{global}{audit_enabled}) {
        $server->plugin('AuditLog');
    }
    # Load arbitrary plugins defined in config: 'plugins' in section
    # '[global]' can be a space-separated list of plugins to load, by
    # module name under OpenQA::WebAPI::Plugin::
    if (defined $server->config->{global}->{plugins}) {
        my @plugins = split(' ', $server->config->{global}->{plugins});
        for my $plugin (@plugins) {
            $server->log->info("Loading external plugin $plugin");
            $server->plugin($plugin);
        }
    }
    if ($server->config->{global}{profiling_enabled}) {
        $server->plugin(NYTProf => {nytprof => {}});
    }
    if ($monitoring_root_route && $server->config->{global}{monitoring_enabled}) {
        $server->plugin(Status => {route => $monitoring_root_route->get('/monitoring')});
    }
    # load auth module
    my $auth_method = $server->config->{auth}->{method};
    my $auth_module = "OpenQA::WebAPI::Auth::$auth_method";
    eval "require $auth_module";    ## no critic
    if ($@) {
        die sprintf('Unable to load auth module %s for method %s', $auth_module, $auth_method);
    }

    # Read configurations expected by plugins.
    OpenQA::Setup::update_config($server->config, @{$server->plugins->namespaces}, "OpenQA::WebAPI::Auth");
}

sub set_secure_flag_on_cookies {
    my ($controller) = @_;
    if ($controller->req->is_secure) {
        $controller->app->sessions->secure(1);
    }
    if (my $days = $controller->app->config->{global}->{hsts}) {
        $controller->res->headers->header(
            'Strict-Transport-Security' => sprintf('max-age=%d; includeSubDomains', $days * 24 * 60 * 60));
    }
}

sub set_secure_flag_on_cookies_of_https_connection {
    my ($server) = @_;
    $server->hook(before_dispatch => \&set_secure_flag_on_cookies);
}

sub setup_validator_check_for_datetime {
    my ($server) = @_;
    $server->validator->add_check(
        datetime => sub {
            my ($validation, $name, $value) = @_;
            eval { DateTime::Format::Pg->parse_datetime($value); };
            if ($@) {
                return 1;
            }
            return;
        });
}

# add build_tx time to the header for HMAC time stamp check to avoid large timeouts on uploads
sub add_build_tx_time_header {
    my ($app) = @_;
    $app->hook(
        after_build_tx => sub {
            my ($tx, $app) = @_;
            $tx->req->headers->header('X-Build-Tx-Time' => time);
        });
}

1;
