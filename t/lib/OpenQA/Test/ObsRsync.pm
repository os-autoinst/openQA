# Copyright (C) 2021 SUSE LLC
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

package OpenQA::Test::ObsRsync;
use Test::Most;
use Mojo::Base -base, -signatures;

use Exporter 'import';
use FindBin;
use OpenQA::Test::Case;
use Mojo::File qw(tempdir path);
use File::Copy::Recursive 'dircopy';

our (@EXPORT, @EXPORT_OK);
@EXPORT_OK = (qw(setup_obs_rsync_test));

sub setup_obs_rsync_test {
    my $tempdir       = tempdir;
    my $home_template = path(__FILE__)->dirname->dirname->dirname->dirname->child('data', 'openqa-trigger-from-obs');
    my $home          = path($tempdir, 'openqa-trigger-from-obs');
    dircopy($home_template, $home);
    $tempdir->child('openqa.ini')->spurt(<<"EOF");
[global]
plugins=ObsRsync
[obs_rsync]
home=$home
EOF

    my $schema     = OpenQA::Test::Case->new(config_directory => $tempdir)->init_data(fixtures_glob => '03-users.pl');
    my $t          = Test::Mojo->new('OpenQA::WebAPI');
    my $token      = $t->get_ok('/')->tx->res->dom->at('meta[name=csrf-token]')->attr('content');
    my %params     = ('X-CSRF-Token' => $token);
    my $login_code = $t->get_ok('/login')->tx->res->code;
    BAIL_OUT "login return code is $login_code, expected 302 (redirection)" unless $login_code == 302;

    return ($t, $tempdir, $home, \%params, $schema);
}

1;
