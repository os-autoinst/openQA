BEGIN { unshift @INC, 'lib'; }

# Copyright (C) 2014 SUSE Linux Products GmbH
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use Mojo::Base -strict;
use FindBin;
use lib "$FindBin::Bin/lib";

use Test::More;
use Test::Warnings;
use Mojolicious;
use OpenQA::ServerStartup;

subtest 'Test configuration default modes' => sub {
    local $ENV{OPENQA_CONFIG} = undef;

    my $app = Mojolicious->new();
    $app->mode("test");
    OpenQA::ServerStartup::read_config($app);
    my $config = $app->config;
    is(length($config->{_openid_secret}), 16, "config has openid_secret");
    my $test_config = {
        global => {
            appname             => 'openQA',
            branding            => 'openSUSE',
            hsts                => 365,
            audit_enabled       => 1,
            max_rss_limit       => 0,
            profiling_enabled   => 0,
            hide_asset_types    => 'repo',
            recognized_referers => []
        },
        auth => {
            method => 'Fake',
        },
        'scm git' => {
            do_push => 'no',
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
        }};

    # Test configuration generation with "test" mode
    $test_config->{_openid_secret} = $config->{_openid_secret};
    $test_config->{logging}->{level} = "debug";
    is_deeply $config, $test_config, '"test" configuration';

    # Test configuration generation with "development" mode
    $app = Mojolicious->new();
    $app->mode("development");
    OpenQA::ServerStartup::read_config($app);
    $config = $app->config;
    $test_config->{_openid_secret} = $config->{_openid_secret};
    is_deeply $config, $test_config, 'right "development" configuration';

    # Test configuration generation with an unknown mode (should fallback to default)
    $app = Mojolicious->new();
    $app->mode("foo_bar");
    OpenQA::ServerStartup::read_config($app);
    $config                        = $app->config;
    $test_config->{_openid_secret} = $config->{_openid_secret};
    $test_config->{auth}->{method} = "OpenID";
    delete $test_config->{logging};
    is_deeply $config, $test_config, 'right default configuration';


    # Test configuration generation with an unknown mode (should fallback to default)
    $app = Mojolicious->new();
    $app->mode("foo_bar");
    OpenQA::ServerStartup::read_config($app);
    $config                        = $app->config;
    $test_config->{_openid_secret} = $config->{_openid_secret};
    $test_config->{auth}->{method} = "OpenID";
    delete $test_config->{logging};
    is_deeply $config, $test_config, 'right default configuration';

};

subtest 'Test configuration override from file' => sub {
    use Mojo::File 'tempdir';

    my $t_dir = tempdir;
    local $ENV{OPENQA_CONFIG} = $t_dir;
    my $app  = Mojolicious->new();
    my @data = (
        "[global]\n",
        "suse_mirror=http://blah/\n",
"recognized_referers = bugzilla.suse.com bugzilla.opensuse.org bugzilla.novell.com bugzilla.microfocus.com progress.opensuse.org github.com\n",
        "[audit]\n",
        "blacklist = job_grab job_done\n"
    );
    $t_dir->child("openqa.ini")->spurt(@data);
    OpenQA::ServerStartup::read_config($app);

    ok -e $t_dir->child("openqa.ini");
    ok($app->config->{global}->{suse_mirror} eq 'http://blah/',   'suse mirror');
    ok($app->config->{audit}->{blacklist} eq 'job_grab job_done', 'audit blacklist');

    is_deeply(
        $app->config->{global}->{recognized_referers},
        [
            qw(bugzilla.suse.com bugzilla.opensuse.org bugzilla.novell.com bugzilla.microfocus.com progress.opensuse.org github.com)
        ],
        'referers parsed correctly'
    );

};

done_testing();
