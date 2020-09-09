# Copyright (C) 2017-2020 SUSE LLC
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
use Mojo::Base -strict;

use Mojo::File 'path';
use Mojo::Util 'trim';
use Mojo::Loader 'load_class';
use Config::IniFiles;
use OpenQA::App;
use OpenQA::Log 'log_format_callback';
use OpenQA::Utils qw(:DEFAULT assetdir random_string);
use File::Path 'make_path';
use POSIX 'strftime';
use Time::HiRes 'gettimeofday';
use OpenQA::JobGroupDefaults;
use OpenQA::Task::Job::Limit;

sub read_config {
    my $app      = shift;
    my %defaults = (
        global => {
            appname                     => 'openQA',
            base_url                    => undef,
            branding                    => 'openSUSE',
            download_domains            => undef,
            suse_mirror                 => undef,
            scm                         => undef,
            hsts                        => 365,
            audit_enabled               => 1,
            max_rss_limit               => 0,
            profiling_enabled           => 0,
            monitoring_enabled          => 0,
            plugins                     => undef,
            hide_asset_types            => 'repo',
            recognized_referers         => '',
            changelog_file              => '/usr/share/openqa/public/Changelog',
            job_investigate_ignore      => '"(JOBTOKEN|NAME)"',
            job_investigate_git_timeout => 20,
            search_results_limit        => 50000,
        },
        rate_limits => {
            search => 5,
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
        oauth2 => {
            provider => '',
            key      => '',
            secret   => '',
        },
        hypnotoad => {
            listen => ['http://localhost:9526/'],
            proxy  => 1,
        },
        audit => {
            # backward-compatible name definition
            blacklist => '',
            blocklist => '',
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
            retry_interval     => 60,
            retry_max_count    => 1400,
            queue_limit        => 200,
            concurrency        => 2,
            project_status_url => '',
        },
        default_group_limits => {
            asset_size_limit                  => OpenQA::JobGroupDefaults::SIZE_LIMIT_GB,
            log_storage_duration              => OpenQA::JobGroupDefaults::KEEP_LOGS_IN_DAYS,
            important_log_storage_duration    => OpenQA::JobGroupDefaults::KEEP_IMPORTANT_LOGS_IN_DAYS,
            result_storage_duration           => OpenQA::JobGroupDefaults::KEEP_RESULTS_IN_DAYS,
            important_result_storage_duration => OpenQA::JobGroupDefaults::KEEP_IMPORTANT_RESULTS_IN_DAYS,
        },
        misc_limits => {
            untracked_assets_storage_duration         => 14,
            screenshot_cleanup_batch_size             => OpenQA::Task::Job::Limit::DEFAULT_SCREENSHOTS_PER_BATCH,
            screenshot_cleanup_batches_per_minion_job => OpenQA::Task::Job::Limit::DEFAULT_BATCHES_PER_MINION_JOB,
        },
        job_settings_ui => {
            keys_to_render_as_links => '',
            default_data_dir        => 'data',
        },
        'assets/storage_duration' => {
            # intentionally left blank for overview
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
        my @known_keys = sort keys %{$defaults{$section}};
        # if no known_keys defined - just assign every key from the section
        if (!@known_keys && $cfg) {
            for my $k ($cfg->Parameters($section)) {
                $app->config->{$section}->{$k} = $cfg->val($section, $k);
            }
        }
        for my $k (@known_keys) {
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
    if ($app->config->{audit}->{blacklist}) {
        $app->log->warn("Deprecated use of config key '[audit]: blacklist'. Use '[audit]: blocklist' instead");
        $app->config->{audit}->{blocklist} = delete $app->config->{audit}->{blacklist};
    }
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

sub prepare_settings_ui_keys {
    my ($app)     = shift;
    my @link_keys = split ',', $app->config->{job_settings_ui}->{keys_to_render_as_links};
    $app->config->{settings_ui_links} = {map { $_ => 1 } @link_keys};
}

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
    my ($app) = @_;

    $app->routes->any('/*whatever' => {whatever => ''})->to(status => 404, text => 'Not found');

    $app->helper(
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
        $ENV{MOJO_TMPDIR} = assetdir() . '/tmp';
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
    my ($server, $monitoring_root_route, %options) = @_;

    push @{$server->plugins->namespaces}, 'OpenQA::WebAPI::Plugin';

    foreach my $plugin (qw(Helpers MIMETypes CSRF REST HashedParams Gru YAML)) {
        $server->plugin($plugin);
    }

    if ($server->config->{global}{audit_enabled}) {
        $server->plugin('AuditLog');
    }
    # Load arbitrary plugins defined in config: 'plugins' in section
    # '[global]' can be a space-separated list of plugins to load, by
    # module name under OpenQA::WebAPI::Plugin::
    if (defined $server->config->{global}->{plugins} && !$options{no_arbitrary_plugins}) {
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
    if (my $err = load_class $auth_module) {
        $err = 'Module not found' unless ref $err;
        die "Unable to load auth module $auth_module: $err";
    }
    # Optional initialization with access to the app
    if (my $sub = $auth_module->can('auth_setup')) {
        $server->$sub;
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
