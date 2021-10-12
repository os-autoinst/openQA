# Copyright 2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Test::ObsRsync;
use Test::Most;
use Mojo::Base -base, -signatures;

use Exporter 'import';
use FindBin;
use OpenQA::Test::Case;
use Test::Mojo;
use Mojo::File qw(tempdir path);
use File::Copy::Recursive 'dircopy';

our (@EXPORT, @EXPORT_OK);
@EXPORT_OK = (qw(setup_obs_rsync_test));

sub setup_obs_rsync_test (%args) {
    my $tempdir = tempdir;
    my $home_template = path(__FILE__)->dirname->dirname->dirname->dirname->child('data', 'openqa-trigger-from-obs');
    my $home = path($tempdir, 'openqa-trigger-from-obs');
    my $url = delete $args{url} // '';
    my $more_config = delete $args{config} // {};
    my $more_config_str = join("\n", map { "$_=$more_config->{$_}" } keys %$more_config);
    dircopy($home_template, $home);
    $tempdir->child('openqa.ini')->spurt(<<"EOF");
[global]
plugins=ObsRsync
[obs_rsync]
project_status_url=$url
home=$home
$more_config_str
EOF

    my $case = OpenQA::Test::Case->new(config_directory => $tempdir);
    my $schema = $case->init_data(fixtures_glob => '03-users.pl', %args);
    my $t = Test::Mojo->new('OpenQA::WebAPI');
    my $token = $t->get_ok('/')->tx->res->dom->at('meta[name=csrf-token]')->attr('content');
    my %params = ('X-CSRF-Token' => $token);
    my $login_code = $t->get_ok('/login')->tx->res->code;
    BAIL_OUT "login return code is $login_code, expected 302 (redirection)" unless $login_code == 302;

    return ($t, $tempdir, $home, \%params, $schema);
}

1;
