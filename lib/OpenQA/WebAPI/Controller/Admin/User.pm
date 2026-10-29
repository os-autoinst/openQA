# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::Admin::User;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use HTTP::Status qw(:constants);
use Crypt::PRNG 'random_string';
use Mojo::JSON 'encode_json';
use OpenQA::WebAPI::Auth::Local qw(hash_password);
use OpenQA::Shared::Controller::Session;

sub index ($self) {
    my @users = $self->schema->resultset('Users')->search(undef)->all;

    $self->stash('users', \@users);
    $self->render('admin/user/index');
}

sub update ($self) {
    my $set = $self->schema->resultset('Users');
    my $is_admin = 0;
    my $is_operator = 0;
    my $role = $self->param('role') // 'user';

    if ($role eq 'admin') {
        $is_admin = 1;
        $is_operator = 1;
    }
    elsif ($role eq 'operator') {
        $is_operator = 1;
    }

    my $err = 0;
    my $msg = '';

    my $user = $set->find($self->param('userid'));
    if (!$user) {
        $err = HTTP_NOT_FOUND;
        $msg = "Can't find that user";
    }
    elsif (($user->provider // '') eq '' && $user->username eq 'system') {
        $err = HTTP_FORBIDDEN;
        $msg = 'Cannot change role of system user';
    }
    elsif ($user->is_admin
        && !$is_admin
        && !$set->search({is_admin => 1, deleted_at => undef, id => {'!=', $user->id}})->count)
    {
        $err = HTTP_FORBIDDEN;
        $msg = 'Cannot demote the last remaining admin';
    }
    else {
        my $old_role = $user->is_admin ? 'admin' : $user->is_operator ? 'operator' : 'user';
        $user->update({is_admin => $is_admin, is_operator => $is_operator});
        $msg = 'User ' . $user->nickname . ' updated';
        my $actor = $self->current_user;
        $self->emit_event(
            'user_update_res',
            {
                nickname => $user->nickname,
                role => $role,
                actor => $actor ? $actor->username : undef,
                old_role => $old_role,
                new_role => $role,
            });
    }

    if (($self->tx->req->headers->accept // '') eq 'application/json') {
        return $self->render(json => {$err ? 'error' : 'status' => $msg}, status => ($err ? $err : HTTP_OK));
    }
    else {
        $self->flash($err ? 'error' : 'info', $msg);
        $self->redirect_to($self->url_for('admin_users'));
    }
}

sub delete ($self) {
    my $user_id = $self->param('id') // $self->param('userid');
    my $user = $self->schema->resultset('Users')->find($user_id);
    return $self->render(text => "Can't find that user", status => HTTP_NOT_FOUND) unless $user;

    return $self->render(text => 'Cannot delete system user', status => HTTP_FORBIDDEN)
      if ($user->provider // '') eq '' && $user->username eq 'system';

    $self->schema->resultset('AuditEvents')->create(
        {
            user_id => $user->id,
            event => 'user_delete_account',
            event_data => '{}',
        });
    $user->anonymize;

    $self->flash(info => 'User deleted successfully.');
    return $self->redirect_to($self->url_for('admin_users'));
}

# Admin-initiated password reset for a local user. The route lives under the admin
# auth matcher, so ensure_admin (session + is_admin + CSRF) already ran before we get here.
sub _render_reset ($self, $status, $msg, $generated = undef) {
    if (($self->tx->req->headers->accept // '') eq 'application/json') {
        my $payload = $status == HTTP_OK ? {status => $msg} : {error => $msg};
        $payload->{generated_password} = $generated if defined $generated;
        return $self->render(json => $payload, status => $status);
    }
    $msg .= " Generated password (shown once): $generated" if defined $generated;
    $self->flash($status == HTTP_OK ? 'info' : 'error', $msg);
    return $self->redirect_to($self->url_for('admin_users'));
}

sub reset_password ($self) {
    my $user = $self->schema->resultset('Users')->find($self->param('userid'));
    return _render_reset($self, HTTP_NOT_FOUND, "Can't find that user") unless $user;

    return _render_reset($self, HTTP_FORBIDDEN, 'Cannot reset password of system user')
      if ($user->provider // '') eq '' && $user->username eq 'system';
    return _render_reset($self, HTTP_FORBIDDEN, 'Cannot reset password of deleted user')
      if $user->is_deleted;
    return _render_reset($self, HTTP_FORBIDDEN, 'Cannot reset password of non-local user')
      if ($user->provider // '') ne 'Local';

    my ($new_password, $mode);
    if ($self->param('generate')) {
        $new_password = random_string(20);
        $mode = 'generated';
    }
    elsif (defined(my $np = $self->param('new_password'))) {
        if (my $err = OpenQA::Shared::Controller::Session::_validate_password($self, $np, $user->username)) {
            return _render_reset($self, HTTP_FORBIDDEN, $err);
        }
        $new_password = $np;
        $mode = 'explicit';
    }
    else {
        return _render_reset($self, HTTP_FORBIDDEN, 'Provide new_password or generate=1');
    }

    my $keep_api_keys = $self->param('keep_api_keys') ? 1 : 0;
    unless ($keep_api_keys) {
        $user->api_keys->delete;
    }

    # Bump session_epoch so any browser session for the target stops resolving to them.
    $user->update({password => hash_password($new_password), session_epoch => ($user->session_epoch // 0) + 1});

    $self->schema->resultset('AuditEvents')->create(
        {
            user_id => $user->id,
            event => 'user_password_reset',
            event_data => encode_json(
                {
                    mode => $mode,
                    username => $user->username,
                    revoked_api_keys => $keep_api_keys ? 0 : 1,
                }
            ),
        });

    if (my $current = $self->current_user) {
        delete $self->session->{user} if $current->id == $user->id;
    }

    my $msg = 'Password of user ' . ($user->nickname // $user->username) . ' reset';
    return _render_reset($self, HTTP_OK, $msg, $mode eq 'generated' ? $new_password : undef);
}

1;
