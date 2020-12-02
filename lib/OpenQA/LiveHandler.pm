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

use OpenQA::Schema;
use OpenQA::Log 'setup_log';
use OpenQA::Setup;

has secrets => sub { shift->schema->read_application_secrets };

# add attributes to store ws connections/transactions by job
# (see LiveViewHandler.pm for further descriptions of the paricular attributes)
has [qw(cmd_srv_transactions_by_job devel_java_script_transactions_by_job status_java_script_transactions_by_job)] =>
  sub { {} };

sub log_name { $$ }

# This method will run once at server start
sub startup {
    my $self = shift;

    $self->defaults(appname => 'openQA Live Handler');

    $self->ua->max_redirects(3);

    # Provide help to users early to prevent failing later on
    # misconfigurations
    return if $ENV{MOJO_HELP};

    OpenQA::Setup::read_config($self);
    setup_log($self);
    OpenQA::Setup::add_build_tx_time_header($self);

    # Some plugins are shared between openQA micro services
    push @{$self->plugins->namespaces}, 'OpenQA::LiveHandler::Plugin', 'OpenQA::Shared::Plugin';
    $self->plugin('SharedHelpers');
    $self->plugin('CSRF');

    OpenQA::Setup::set_secure_flag_on_cookies_of_https_connection($self);

    # Some controllers are shared between openQA micro services
    my $r = $self->routes->namespaces(['OpenQA::Shared::Controller', 'OpenQA::LiveHandler::Controller']);

    # register root routes: use same paths as the regular web UI but prefix everything with /liveviewhandler
    $r->get('/' => {json => {name => $self->defaults('appname')}});
    my $test_r = $r->route('/liveviewhandler/tests/:testid', testid => qr/\d+/);
    my $api_ro = $r->under('/liveviewhandler/api/v1')->to('Auth#auth_operator');

    # register websocket routes
    my $developer_auth = $test_r->under('/developer')->to('Session#ensure_operator');
    my $developer_r    = $developer_auth->route('/');
    $developer_r->websocket('/ws-proxy')->name('developer_ws_proxy')->to('live_view_handler#ws_proxy');
    $test_r->websocket('/developer/ws-proxy/status')->name('status_ws_proxy')->to('live_view_handler#proxy_status');

    # register API routes
    my $job_r = $api_ro->route('/jobs/:testid', testid => qr/\d+/);
    $job_r->post('/upload_progress')->name('developer_post_upload_progress')
      ->to('live_view_handler#post_upload_progress');

    OpenQA::Setup::setup_plain_exception_handler($self);
}

sub run { __PACKAGE__->new->start; die "HERE" }

sub schema { OpenQA::Schema->singleton }

1;
