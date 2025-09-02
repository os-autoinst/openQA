# Copyright 2019-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Shared::Plugin::SharedHelpers;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use Mojo::URL;
use OpenQA::Schema;
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;

sub register ($self, $app, @) {
    $app->helper(schema => sub { OpenQA::Schema->singleton });
    $app->helper(find_current_job => \&_find_current_job);

    $app->helper(determine_connection_params_for_job => \&_determine_connection_params_for_job);
    $app->helper(determine_os_autoinst_web_socket_url => \&_determine_os_autoinst_web_socket_url);

    $app->helper(current_user => \&_current_user);
    $app->helper(is_operator => \&_is_operator);
    $app->helper(is_admin => \&_is_admin);
    $app->helper(is_local_request => \&_is_local_request);
    $app->helper(render_specific_not_found => \&_render_specific_not_found);
    $app->helper(via_subdomain => \&_via_subdomain);
}

# returns the isotovideo command server web socket URL and the VNC argument for the given job or undef if not available
sub _determine_connection_params_for_job ($c, $job) {
    return undef unless $job->state eq OpenQA::Jobs::Constants::RUNNING;

    # determine job token and host from worker
    return undef unless my $worker = $job->assigned_worker;
    return undef unless my $job_token = $worker->get_property('JOBTOKEN');
    return undef unless my $host = $worker->get_property('WORKER_HOSTNAME') || $worker->host;

    # determine port
    my $cmd_srv_raw_url = $worker->get_property('CMD_SRV_URL') or return;
    my $cmd_srv_url = Mojo::URL->new($cmd_srv_raw_url);
    my $port = $cmd_srv_url->port() or return;
    return ("ws://$host:$port/$job_token/ws", $worker->vnc_argument);
}

sub _determine_os_autoinst_web_socket_url ($c, $job) { (_determine_connection_params_for_job($c, $job))[0] }

sub _find_current_job ($c) {
    return undef unless my $test_id = $c->param('testid');
    return $c->helpers->schema->resultset('Jobs')->find($test_id);
}

sub _current_user ($c) {
    # If the value is not in the stash
    my $current_user = $c->stash('current_user');
    unless ($current_user && ($current_user->{no_user} || defined $current_user->{user})) {
        my $id = $c->session->{user};
        my $user = $id ? $c->schema->resultset('Users')->find({username => $id}) : undef;
        $c->stash(current_user => $current_user = $user ? {user => $user} : {no_user => 1});
    }

    return $current_user && defined $current_user->{user} ? $current_user->{user} : undef;
}

sub _is_operator ($c, $user = undef) {
    $user //= $c->current_user;
    return ($user && $user->is_operator);
}

sub _is_admin ($c, $user = undef) {
    $user //= $c->current_user;
    return ($user && $user->is_admin);
}

sub _is_local_request ($c) {
    # IPv4 and IPv6 should be treated the same
    my $address = $c->tx->remote_address;
    return $address eq '127.0.0.1' || $address eq '::1';
}

sub _render_specific_not_found ($c, $title, $error_message) {
    $c->res->headers->content_type('text/plain');
    return $c->render(status => 404, text => "$title - $error_message");
}

sub _via_subdomain ($c, $subdomain) {
    return 0 unless defined $subdomain;
    return index($c->req->url->to_abs->host, $subdomain) == 0;
}

1;
