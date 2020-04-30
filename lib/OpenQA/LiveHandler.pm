# Copyright (C) 2018-2020 SUSE LLC
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
use Mojo::Base 'Mojolicious';

use Mojolicious 7.18;
use OpenQA::Schema;
use OpenQA::WebAPI::Plugin::Helpers;
use OpenQA::Log 'setup_log';
use OpenQA::Setup;
use Mojo::IOLoop;
use Mojolicious::Commands;
use DateTime;
use Cwd 'abs_path';
use File::Path 'make_path';
use BSD::Resource 'getrusage';

has secrets => sub {
    my ($self) = @_;
    return $self->schema->read_application_secrets();
};

# add attributes to store ws connections/transactions by job
# (see LiveViewHandler.pm for further descriptions of the paricular attributes)
has [qw(cmd_srv_transactions_by_job devel_java_script_transactions_by_job status_java_script_transactions_by_job)] =>
  sub { {} };

sub log_name {
    return $$;
}

# This method will run once at server start
sub startup {
    my $self = shift;

    $self->defaults(appname => 'openQA Live Handler');
    # Provide help to users early to prevent failing later on
    # misconfigurations
    return if $ENV{MOJO_HELP};
    OpenQA::Setup::read_config($self);
    setup_log($self);
    OpenQA::Setup::setup_mojo_tmpdir();
    OpenQA::Setup::add_build_tx_time_header($self);

    # take care of DB deployment or migration before starting the main app
    my $schema = $self->schema;

    OpenQA::Setup::load_plugins($self, undef, no_arbitrary_plugins => 1);
    OpenQA::Setup::set_secure_flag_on_cookies_of_https_connection($self);

    # register root routes: use same paths as the regular web UI but prefix everything with /liveviewhandler
    my $r = $self->routes;
    $r->get('/' => {json => {name => $self->defaults('appname')}});
    my $test_r
      = $r->route('/liveviewhandler/tests/:testid', testid => qr/\d+/)->to(namespace => 'OpenQA::WebAPI::Controller');
    $test_r = $test_r->under('/')->to('test#referer_check');
    my $api_auth_operator = $r->under('/liveviewhandler/api/v1')->to(
        namespace  => 'OpenQA::WebAPI::Controller',
        controller => 'API::V1',
        action     => 'auth_operator'
    );
    my $api_ro = $api_auth_operator->route('/')->to(namespace => 'OpenQA::WebAPI::Controller::API::V1');

    # register websocket routes
    my $developer_auth = $test_r->under('/developer')->to('session#ensure_operator');
    my $developer_r    = $developer_auth->route('/')->to(namespace => 'OpenQA::WebAPI::Controller');
    $developer_r->websocket('/ws-proxy')->name('developer_ws_proxy')->to('live_view_handler#ws_proxy');
    $test_r->websocket('/developer/ws-proxy/status')->name('status_ws_proxy')->to('live_view_handler#proxy_status');

    # register API routes
    my $job_r = $api_ro->route('/jobs/:testid', testid => qr/\d+/);
    $job_r->post('/upload_progress')->name('developer_post_upload_progress')->to(
        namespace  => 'OpenQA::WebAPI::Controller',
        controller => 'LiveViewHandler',
        action     => 'post_upload_progress'
    );

    # don't try to render default 404 template, instead just render 'route not found' vis ws connection or regular HTTP
    my $not_found_r = $r->route('/')->to(namespace => 'OpenQA::WebAPI::Controller');
    $not_found_r->websocket('*')->to('live_view_handler#not_found_ws');
    $not_found_r->any('*')->to('live_view_handler#not_found_http');

    OpenQA::Setup::setup_plain_exception_handler($self);
    OpenQA::Setup::setup_validator_check_for_datetime($self);
}

sub run { __PACKAGE__->new->start }

sub schema { OpenQA::Schema->singleton }

1;
