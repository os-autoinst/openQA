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
    $app->helper(parse_api_key_roles => \&_parse_api_key_roles);
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

# In openQA, administrator status implies operator access across all controllers.
# When an API key is stashed, operator access requires either valid operator
# permissions on both user and key, or valid administrator permissions on both.
# Caller passing an explicit $user argument inspects that specific user account's
# permissions directly without applying API key scoping.
sub _is_operator ($c, $user = undef) {
    if (!$user) {
        $user = $c->current_user;
        if (my $api_key = $c->stash('current_api_key')) {
            return ($user
                  && (($user->is_admin && $api_key->is_admin) || ($user->is_operator && $api_key->is_operator)));
        }
    }
    return ($user && $user->is_operator);
}

sub _is_admin ($c, $user = undef) {
    if (!$user) {
        $user = $c->current_user;
        if (my $api_key = $c->stash('current_api_key')) {
            return ($user && $user->is_admin && $api_key->is_admin);
        }
    }
    return ($user && $user->is_admin);
}

# Format effective role string ('Administrator', 'Operator', or 'User')
# for display based on key flags bounded by user account roles.
# Arguments: $c (controller), $key (api key object), $user (optional user object, defaults to current_user)
sub _format_api_key_role ($c, $key, $user = undef) {
    $user //= $c->current_user;
    return 'User' unless $user && $key;
    return 'Administrator' if $key->is_admin && $user->is_admin;
    return 'Operator' if $key->is_operator && ($user->is_admin || $user->is_operator);
    return 'User';
}

# Parse requested role or is_operator/is_admin parameters when creating an API key.
# New keys without explicit parameters default to the creator's current roles.
# Returns ($is_operator, $is_admin, $error_msg).
sub _parse_api_key_roles ($c, $role, $validation, $user) {
    if (defined $role && ($validation->is_valid('is_operator') || $validation->is_valid('is_admin'))) {
        return (undef, undef, 'Cannot specify both role and is_operator/is_admin');
    }
    my ($is_operator, $is_admin);
    if (defined $role) {
        if ($role eq 'admin') {
            ($is_operator, $is_admin) = (1, 1);
        }
        elsif ($role eq 'operator') {
            ($is_operator, $is_admin) = (1, 0);
        }
        else {
            ($is_operator, $is_admin) = (0, 0);
        }
    }
    else {
        $is_operator
          = $validation->is_valid('is_operator') ? int($validation->param('is_operator')) : $user->is_operator;
        $is_admin = $validation->is_valid('is_admin') ? int($validation->param('is_admin')) : $user->is_admin;
    }
    return ($is_operator, $is_admin, undef);
}

# Verify requested roles do not exceed the calling user's account roles.
sub _validate_api_key_role_grant ($c, $is_admin, $is_operator, $user) {
    if ($is_admin && !$user->is_admin) {
        return 'Cannot grant administrator role exceeding own account';
    }
    if ($is_operator && !$user->is_operator && !$user->is_admin) {
        return 'Cannot grant operator role exceeding own account';
    }
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
