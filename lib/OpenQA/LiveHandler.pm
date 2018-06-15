# Copyright (C) 2018 SUSE Linux GmbH
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

package OpenQA::LiveHandler;
use strict;

use Mojolicious 7.18;
use Mojo::Base 'Mojolicious';
use OpenQA::Schema;
use OpenQA::WebAPI::Plugin::Helpers;
use OpenQA::Utils qw(log_warning detect_current_version);
use OpenQA::Setup;
use Mojo::IOLoop;
use Mojolicious::Commands;
use DateTime;
use Cwd 'abs_path';
use File::Path 'make_path';
use BSD::Resource 'getrusage';

has schema => sub {
    return OpenQA::Schema::connect_db();
};

has secrets => sub {
    my ($self) = @_;
    return $self->schema->read_application_secrets();
};

sub log_name {
    return $$;
}

# This method will run once at server start
sub startup {
    my $self = shift;
    OpenQA::Setup::read_config($self);
    OpenQA::Setup::setup_log($self);
    OpenQA::Setup::setup_app_defaults($self);
    OpenQA::Setup::setup_mojo_tmpdir();

    # take care of DB deployment or migration before starting the main app
    my $schema = OpenQA::Schema::connect_db;

    OpenQA::Setup::setup_template_search_path($self);
    OpenQA::Setup::load_plugins($self);
    OpenQA::Setup::set_secure_flag_on_cookies_of_https_connection($self);

    # register routes
    my $r = $self->routes;
    my $test_r
      = $r->route('/liveviewhandler/tests/:testid', testid => qr/\d+/)->to(namespace => 'OpenQA::WebAPI::Controller');
    $test_r = $test_r->under('/')->to('test#referer_check');

    my $developer_auth = $test_r->under('/developer')->to('session#ensure_admin');
    my $developer_r = $developer_auth->route('/')->to(namespace => 'OpenQA::WebAPI::Controller');
    $developer_r->websocket('/ws-proxy')->name('developer_ws_proxy')->to('live_view_handler#ws_proxy');
    $test_r->websocket('/developer/ws-proxy/status')->name('status_ws_proxy')->to('live_view_handler#proxy_status');

    OpenQA::Setup::setup_validator_check_for_datetime($self);
}

sub run {
    Mojolicious::Commands->start_app('OpenQA::LiveHandler');
}

1;
