# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Shared::Plugin::SharedHelpers;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use Mojo::URL;
use OpenQA::Schema;
use OpenQA::Constants 'DEFAULT_ADMIN';
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;

sub register ($self, $app, @args) {
    $app->helper(schema => sub { OpenQA::Schema->singleton });
    $app->helper(find_current_job => \&_find_current_job);

    $app->helper(determine_connection_params_for_job => \&_determine_connection_params_for_job);
    $app->helper(determine_os_autoinst_web_socket_url => \&_determine_os_autoinst_web_socket_url);

    $app->helper(current_user => \&_current_user);
    $app->helper(is_operator => \&_is_operator);
    $app->helper(is_admin => \&_is_admin);
    $app->helper(format_api_key_role => \&_format_api_key_role);
    $app->helper(role_to_permissions => \&_role_to_permissions);
    $app->helper(validate_api_key_role_grant => \&_validate_api_key_role_grant);
    $app->helper(is_api_request => \&_is_api_request);
    $app->helper(is_local_request => \&_is_local_request);
    $app->helper(render_specific_not_found => \&_render_specific_not_found);
    $app->helper(via_domain => \&_via_domain);
}

# returns the isotovideo command server web socket URL and connection params for the given job or undef
sub _determine_connection_params_for_job ($c, $job) {
    return undef unless $job->state eq OpenQA::Jobs::Constants::RUNNING;

    # determine job token and host from worker
    return undef unless my $worker = $job->assigned_worker;
    return undef unless my $job_token = $worker->get_property('JOBTOKEN');
    return undef unless my $host = $worker->get_property('WORKER_HOSTNAME') || $worker->host;

    # determine port
    my $cmd_srv_raw_url = $worker->get_property('CMD_SRV_URL') or return undef;
    my $cmd_srv_url = Mojo::URL->new($cmd_srv_raw_url);
    my $port = $cmd_srv_url->port() or return undef;
    return (
        "ws://$host:$port/$job_token/ws",
        {
            vnc_arg => $worker->vnc_argument,
            developer_connection_hint => $worker->developer_connection_hint,
        });
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
        my $is_auth_method_none = ($c->app->config->{auth}->{method} // '') eq 'None';
        # Avoid auto-login as admin for requests with API credentials.
        # Otherwise, the 'auth' method would reject the request due to a
        # missing CSRF token before it even checks the API credentials.
        my $id = $c->session->{user} // ($is_auth_method_none && !$c->is_api_request ? DEFAULT_ADMIN : undef);
        my $users = $c->schema->resultset('Users');
        my $user = $id ? $users->find({username => $id}) : undef;
        if ($is_auth_method_none && $id && $id eq DEFAULT_ADMIN) {
            $user ||= $users->create_user(DEFAULT_ADMIN, fullname => 'Administrator', email => 'admin@example.com');
            $user->update({is_admin => 1, is_operator => 1}) unless $user->is_admin && $user->is_operator;
        }
        $c->stash(current_user => $current_user = $user ? {user => $user} : {no_user => 1});
    }

    return $current_user && defined $current_user->{user} ? $current_user->{user} : undef;
}

sub _is_operator ($c) {
    my $user = $c->current_user;
    return 0 unless $user;
    my $api_key = $c->stash('current_api_key');
    return ($user->is_admin && $api_key->is_admin) || ($user->is_operator && $api_key->is_operator) if $api_key;
    return $user->is_admin || $user->is_operator;
}

sub _is_admin ($c) {
    my $user = $c->current_user;
    return 0 unless $user;
    my $api_key = $c->stash('current_api_key');
    return $user->is_admin && $api_key->is_admin if $api_key;
    return $user->is_admin;
}

sub _format_api_key_role ($c, $key, $user = undef) {
    $user //= $c->current_user;
    return 'User' unless $user && $key;
    return 'Administrator' if $key->is_admin && $user->is_admin;
    return 'Operator' if $key->is_operator && ($user->is_admin || $user->is_operator);
    return 'User';
}

sub _role_to_permissions ($c, $role) {
    return (1, 1) if $role eq 'admin';
    return (1, 0) if $role eq 'operator';
    return (0, 0);
}

sub _validate_api_key_role_grant ($c, $is_admin, $is_operator) {
    return 'Cannot grant administrator role exceeding own permissions' if $is_admin && !$c->is_admin;
    return 'Cannot grant operator role exceeding own permissions' if $is_operator && !$c->is_operator;
    return undef;
}

sub _is_api_request ($c) {
    my $h = $c->req->headers;
    return !!($h->authorization || $h->header('X-API-Key') || $h->header('X-API-Microtime'));
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

sub _via_domain ($c, $domain) { defined $domain && $c->req->url->to_abs->host eq $domain }

1;

=encoding utf8

=head1 NAME

OpenQA::Shared::Plugin::SharedHelpers - Shared Mojolicious helpers for openQA

=head1 DESCRIPTION

Registers helpers for schema access, the current user and role checks,
API-key permission scoping, request classification, and rendering.

=head2 is_operator

Returns true if the current user has operator access. Administrator access
implies operator access. When the request is authenticated with an API key,
the key must also carry the matching C<is_operator> or C<is_admin> flag.

=head2 is_admin

Returns true if the current user is an administrator. When the request is
authenticated with an API key, the key must also be an administrator.

=head2 format_api_key_role

Returns the effective role of an API key (C<Administrator>, C<Operator>, or
C<User>), bounded by the owning user's account roles.

=head2 role_to_permissions

Maps a role name (C<admin>, C<operator>, or C<user>) to an C<is_operator> and
C<is_admin> permission pair.

=head2 validate_api_key_role_grant

Returns an error message if the requested permissions exceed the effective
permissions of the current request (the account roles bounded by the
authenticating API key's scope), or C<undef> when the grant is allowed.

=cut
